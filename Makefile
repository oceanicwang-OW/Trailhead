# 行迹 Trailhead — 开发常用命令
# 用法：make <目标>。先 `make doctor` 确认工具链就绪。

PROJECT      := Trailhead.xcodeproj
SCHEME       := Trailhead
IOS_DEST     := platform=iOS Simulator,name=iPhone 17
MAC_DEST     := platform=macOS

.DEFAULT_GOAL := help

.PHONY: help
help: ## 显示可用命令
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: doctor
doctor: ## 检查 Xcode / XcodeGen / SwiftLint / SwiftFormat 是否就绪
	@command -v xcodebuild  >/dev/null && echo "✅ xcodebuild  $$(xcodebuild -version | head -1)" || echo "❌ 缺少 Xcode"
	@command -v xcodegen    >/dev/null && echo "✅ xcodegen    $$(xcodegen --version)"            || echo "❌ brew install xcodegen"
	@command -v swiftlint   >/dev/null && echo "✅ swiftlint   $$(swiftlint version)"             || echo "❌ brew install swiftlint"
	@command -v swiftformat >/dev/null && echo "✅ swiftformat $$(swiftformat --version)"         || echo "❌ brew install swiftformat"

.PHONY: project
project: ## 由 project.yml 生成 Trailhead.xcodeproj
	xcodegen generate

.PHONY: open
open: project ## 生成并在 Xcode 打开
	open $(PROJECT)

.PHONY: build-mac
build-mac: project ## 编译 macOS 版
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(MAC_DEST)' CODE_SIGNING_ALLOWED=NO build

.PHONY: build-ios
build-ios: project ## 编译 iOS 模拟器版
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(IOS_DEST)' CODE_SIGNING_ALLOWED=NO build

.PHONY: build
build: build-mac build-ios ## 双端编译

.PHONY: test-core
test-core: ## 跑 TrailheadCore 单测（hostless，macOS 秒级）
	cd Packages/TrailheadCore && xcodebuild test -scheme TrailheadCore -destination 'platform=macOS'

.PHONY: test-app
test-app: project ## 跑 App 单测（macOS host）
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination '$(MAC_DEST)' CODE_SIGNING_ALLOWED=NO

.PHONY: test
test: test-core test-app ## 跑全部单测

.PHONY: lint
lint: ## SwiftLint 检查
	swiftlint lint --config .swiftlint.yml

.PHONY: format
format: ## SwiftFormat 自动格式化
	swiftformat .

.PHONY: hooks
hooks: ## 启用提交前机密拦截钩子（.githooks/pre-commit）
	git config core.hooksPath .githooks
	@echo "✅ core.hooksPath = .githooks（提交将自动拦截密钥/凭据）"

.PHONY: clean
clean: ## 清理生成物
	rm -rf $(PROJECT) build DerivedData
