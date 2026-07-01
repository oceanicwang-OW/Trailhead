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

struct MapInspector: View {
    let trip: Trip
    let dayIndex: Int
    @Binding var selectedItemID: UUID?
    @Binding var mapFocus: MapFocus?

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
        ZStack(alignment: .bottom) {
            Map(position: $camera) {
                ForEach(Array(pois.enumerated()), id: \.element.id) { idx, item in
                    if let c = coord(item) {
                        Annotation(item.name ?? "", coordinate: c) {
                            pin(index: idx + 1, color: item.kind.color,
                                selected: selectedItemID == item.id)
                                .onTapGesture { selectedItemID = item.id }
                        }
                    }
                }
                if let f = mapFocus {
                    Annotation(f.name, coordinate: .init(latitude: f.lat, longitude: f.lng)) {
                        focusPin(f)
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat))

            if let item = selectedPOI { detailCard(item).padding(14) }
        }
        // 地图跟随行程：切换行程或天数时，自动定位到当天 POI 的范围（并清掉旧焦点）。
        .onAppear { recenter(animated: false) }
        .onChange(of: trip.id) { mapFocus = nil; recenter() }
        .onChange(of: dayIndex) { mapFocus = nil; recenter() }
        // 点击美食/住宿卡片：飞到该点。
        .onChange(of: mapFocus) { _, f in if let f { focusCamera(f) } }
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

    private var selectedPOI: PlanItem? {
        pois.first { $0.id == selectedItemID } ?? pois.first
    }

    private func pin(index: Int, color: Color, selected: Bool) -> some View {
        Text("\(index)")
            .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
            .frame(width: selected ? 26 : 22, height: selected ? 26 : 22)
            .background(color, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2.5))
            .shadow(radius: 2, y: 1)
    }

    private func detailCard(_ item: PlanItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.name ?? "").font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.textPrimary)
                Spacer()
                Text("\(item.kind.label) · \(item.subtype ?? "")")
                    .font(Typo.tag).foregroundStyle(item.kind.color)
                    .padding(.vertical, 2).padding(.horizontal, 7)
                    .background(item.kind.color.opacity(0.12), in: Capsule())
            }
            if let note = item.note, !note.isEmpty {
                Text(note).font(Typo.caption).foregroundStyle(Palette.textSecondary)
            }
            if let stay = item.stayLabel, !stay.isEmpty {
                Label(stay, systemImage: "clock").font(Typo.caption).foregroundStyle(Palette.textMuted)
            }
            Button {} label: {
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
