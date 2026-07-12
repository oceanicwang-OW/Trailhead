//  MapInspector.swift
//  Right column of the macOS main screen: a MapKit map with route pins and the
//  selected-POI detail card. Demo coordinates for the Kyoto Day-1 landmarks;
//  the real build fills PlanItem.lat/lng from Amap (GCJ-02, MapKit-compatible
//  in mainland China — see PDR §2).

import MapKit
import SwiftUI
import TrailheadCore

/// 地图焦点：点击美食/住宿卡片时定位的目标（这些点不在每日动线标注里）。
struct MapFocus: Equatable {
    let id: String
    let name: String
    let lat: Double
    let lng: Double
    let kind: ItemKind   // food / lodging → 针的图标与配色
}

/// 地图与时间线共享的唯一选择状态，避免推荐点和行程点同时处于“选中”。
enum MapSelection: Equatable {
    case itinerary(UUID)
    case recommendation(MapFocus)

    var itineraryID: UUID? {
        guard case let .itinerary(id) = self else { return nil }
        return id
    }

    var recommendationFocus: MapFocus? {
        guard case let .recommendation(focus) = self else { return nil }
        return focus
    }

    func matchesRecommendation(_ id: String) -> Bool {
        recommendationFocus?.id == id
    }
}

@MainActor
final class MapSelectionStore: ObservableObject {
    @Published var selection: MapSelection?
}

struct MapInspector: View {
    let trip: Trip
    let dayIndex: Int
    @ObservedObject var selectionStore: MapSelectionStore
    @Environment(\.openURL) private var openURL

    @State private var camera: MapCameraPosition = .region(
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 34.9956, longitude: 135.7741),
                           span: MKCoordinateSpan(latitudeDelta: 0.16, longitudeDelta: 0.16))
    )

    private var day: DayPlan? { trip.sortedDays.first { $0.dayIndex == dayIndex } }
    private var pois: [PlanItem] { (day?.sortedItems ?? []).filter { $0.kind != .transit } }

    private func coord(_ item: PlanItem) -> CLLocationCoordinate2D? {
        if let lat = item.lat, let lng = item.lng { return .init(latitude: lat, longitude: lng) }
        return Self.demoGeo[item.name ?? ""]
    }

    var body: some View {
        Map(position: $camera) {
            ForEach(Array(pois.enumerated()), id: \.element.id) { idx, item in
                if let c = coord(item) {
                    Annotation(item.name ?? "", coordinate: c) {
                        Button {
                            selectionStore.selection = .itinerary(item.id)
                        } label: {
                            pin(index: idx + 1, color: item.kind.color,
                                selected: selectionStore.selection?.itineraryID == item.id)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("地图地点 \(idx + 1)，\(item.name ?? item.kind.label)")
                        .accessibilityAddTraits(selectionStore.selection?.itineraryID == item.id ? .isSelected : [])
                    }
                }
            }
            if let f = selectionStore.selection?.recommendationFocus {
                Annotation(f.name, coordinate: .init(latitude: f.lat, longitude: f.lng)) {
                    focusPin(f)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .overlay(alignment: .bottom) {
            selectionDetail.padding(14)
        }
        // 地图跟随行程：切换行程或天数时，自动定位到当天 POI 的范围（并清掉旧焦点）。
        .onAppear { recenter(animated: false) }
        .onChange(of: trip.id) { selectionStore.selection = nil; recenter() }
        .onChange(of: dayIndex) { selectionStore.selection = nil; recenter() }
        .onChange(of: selectionStore.selection) { _, value in
            focusCamera(for: value)
        }
    }

    @ViewBuilder private var selectionDetail: some View {
        if let detail = makeDetail(for: selectionStore.selection) {
            detailCard(detail)
                .id(detail.id)
        }
    }

    private func focusCamera(for selection: MapSelection?) {
        switch selection {
        case let .recommendation(focus):
            focusCamera(focus)
        case let .itinerary(id):
            guard let item = pois.first(where: { $0.id == id }), let coordinate = coord(item) else { return }
            withAnimation(.easeInOut(duration: 0.45)) {
                camera = .region(MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.018, longitudeDelta: 0.018)))
            }
        case nil:
            recenter()
        }
    }

    /// 飞到焦点点（近景）。
    private func focusCamera(_ f: MapFocus) {
        withAnimation(.easeInOut(duration: 0.45)) {
            camera = .region(MKCoordinateRegion(
                center: .init(latitude: f.lat, longitude: f.lng),
                span: MKCoordinateSpan(latitudeDelta: 0.018, longitudeDelta: 0.018)))
        }
    }

    private func focusPin(_ f: MapFocus) -> some View {
        Image(systemName: f.kind == .food ? "fork.knife" : "bed.double.fill")
            .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(f.kind.color, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2.5))
            .shadow(radius: 3, y: 1)
    }

    /// 把相机移到当天所有 POI 的外接区域（无坐标则不动）。
    private func recenter(animated: Bool = true) {
        let coords = pois.compactMap(coord)
        guard let region = Self.region(for: coords) else { return }
        if animated { withAnimation(.easeInOut(duration: 0.45)) { camera = .region(region) } } else { camera = .region(region) }
    }

    /// 外接所有坐标并留出边距的区域。
    static func region(for coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard !coords.isEmpty else { return nil }
        let lats = coords.map(\.latitude), lngs = coords.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLng = lngs.min()!, maxLng = lngs.max()!
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLng + maxLng) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.02, (maxLat - minLat) * 1.5),
                                    longitudeDelta: max(0.02, (maxLng - minLng) * 1.5))
        return MKCoordinateRegion(center: center, span: span)
    }

    private struct DetailModel {
        let id: String
        let title: String
        let badge: String
        let kind: ItemKind
        let note: String?
        let stay: String?
        let poiID: String?
    }

    private func makeDetail(for selection: MapSelection?) -> DetailModel? {
        if let focus = selection?.recommendationFocus {
            return DetailModel(id: "recommendation-\(focus.id)", title: focus.name,
                               badge: "推荐 · \(focus.kind.label)", kind: focus.kind,
                               note: nil, stay: nil, poiID: focus.id)
        }
        guard let item = pois.first(where: { $0.id == selection?.itineraryID }) ?? pois.first else { return nil }
        return DetailModel(id: "itinerary-\(item.id.uuidString)", title: item.name ?? "",
                           badge: "\(item.kind.label) · \(item.subtype ?? "")", kind: item.kind,
                           note: item.note, stay: item.stayLabel, poiID: item.poiId)
    }

    private func pin(index: Int, color: Color, selected: Bool) -> some View {
        Text("\(index)")
            .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
            .frame(width: selected ? 26 : 22, height: selected ? 26 : 22)
            .background(color, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2.5))
            .shadow(radius: 2, y: 1)
    }

    private func detailCard(_ detail: DetailModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(detail.title).font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.textPrimary)
                Spacer()
                Text(detail.badge)
                    .font(Typo.tag).foregroundStyle(detail.kind.color)
                    .padding(.vertical, 2).padding(.horizontal, 7)
                    .background(detail.kind.color.opacity(0.12), in: Capsule())
            }
            if let note = detail.note, !note.isEmpty {
                Text(note).font(Typo.caption).foregroundStyle(Palette.textSecondary)
            }
            if let stay = detail.stay, !stay.isEmpty {
                Label(stay, systemImage: "clock").font(Typo.caption).foregroundStyle(Palette.textMuted)
            }
            Button {
                if let poiID = detail.poiID, let url = POILinks.amapDetail(poiId: poiID) { openURL(url) }
            } label: {
                Text("在高德地图打开").font(Typo.caption2.weight(.semibold)).foregroundStyle(Palette.green)
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background(Palette.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain).padding(.top, 2)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }

    // Demo coordinates (WGS-84) for the seeded Kyoto landmarks.
    static let demoGeo: [String: CLLocationCoordinate2D] = [
        "伏见稻荷大社": .init(latitude: 34.9671, longitude: 135.7727),
        "锦市场":      .init(latitude: 35.0050, longitude: 135.7649),
        "清水寺":      .init(latitude: 34.9949, longitude: 135.7851),
        "祇园 · 怀石料理": .init(latitude: 35.0036, longitude: 135.7752),
        "京都町家旅馆":  .init(latitude: 35.0036, longitude: 135.7681),
    ]
}
