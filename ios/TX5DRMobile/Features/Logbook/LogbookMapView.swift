import MapKit
import SwiftUI

struct LogbookMapView: View {
    @EnvironmentObject private var session: TX5DRSession

    let logbookId: String

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var payload: LogbookRecentGlobeResponse.Payload?
    @State private var workedGrids: [LogbookWorkedGridResponse.Payload.Item] = []
    @State private var selectedStation: LogbookMapStation?
    @State private var hours = 24
    @State private var limit = 100
    @State private var band = ""
    @State private var showWorkedGrids = false
    @State private var loading = true
    @State private var errorMessage: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            map

            if loading {
                ProgressView("读取通联地图")
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
            } else if stations.isEmpty {
                ContentUnavailableView(
                    "没有可定位的 QSO",
                    systemImage: "map",
                    description: Text("带有效 Maidenhead 网格的通联会显示在地图上。")
                )
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding()
            }

            summaryBar
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            controls
        }
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle("通联地图")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await reload() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .task(id: requestKey) { await reload() }
        .sheet(item: $selectedStation) { station in
            NavigationStack {
                LogbookMapStationDetail(station: station)
            }
            .presentationDetents([.medium, .large])
        }
        .alert("地图读取失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("重试") { Task { await reload() } }
            Button("取消", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private var map: some View {
        Map(position: $cameraPosition) {
            if showWorkedGrids {
                ForEach(workedGridPolygons) { polygon in
                    MapPolygon(coordinates: polygon.coordinates)
                        .foregroundStyle(RadioPalette.transmit.opacity(polygon.fillOpacity))
                        .stroke(RadioPalette.transmit.opacity(0.46), lineWidth: 0.7)
                }
            }

            ForEach(routes) { route in
                MapPolyline(coordinates: [route.start, route.end])
                    .stroke(
                        route.highlighted ? RadioPalette.transmit.opacity(0.9) : RadioPalette.cyan.opacity(0.38),
                        lineWidth: route.highlighted ? 2.4 : 1.25
                    )
            }

            if let home = homeCoordinate {
                Annotation("本站", coordinate: home, anchor: .center) {
                    ZStack {
                        Circle()
                            .fill(RadioPalette.warning.opacity(0.2))
                            .frame(width: 34, height: 34)
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.caption.bold())
                            .foregroundStyle(RadioPalette.warning)
                            .padding(8)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
            }

            ForEach(stations) { station in
                Annotation(station.grid, coordinate: station.coordinate, anchor: .bottom) {
                    Button { selectedStation = station } label: {
                        VStack(spacing: 2) {
                            Text("\(station.items.count)")
                                .font(.caption2.monospacedDigit().bold())
                                .foregroundStyle(Color.white)
                                .frame(minWidth: 24, minHeight: 24)
                                .background(station.highlighted ? RadioPalette.transmit : RadioPalette.accent, in: Circle())
                            Text(station.grid)
                                .font(.caption2.monospaced().bold())
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.68), in: Capsule())
                        }
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .mapStyle(.standard)
        .mapControls {
            MapCompass()
            MapScaleView()
            MapPitchToggle()
        }
    }

    private var controls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    ForEach([6, 24, 72, 168], id: \.self) { value in
                        Button(value == 24 ? "最近 24 小时" : "最近 \(value) 小时") { hours = value }
                    }
                } label: {
                    mapControlChip("\(hours) 小时", image: "clock")
                }

                Menu {
                    ForEach([50, 100, 200], id: \.self) { value in
                        Button("最多 \(value) 条") { limit = value }
                    }
                } label: {
                    mapControlChip("\(limit) 条", image: "point.3.connected.trianglepath.dotted")
                }

                Menu {
                    Button("全部频段") { band = "" }
                    ForEach(Self.bands, id: \.self) { value in
                        Button(value) { band = value }
                    }
                } label: {
                    mapControlChip(band.isEmpty ? "全部频段" : band, image: "wave.3.right")
                }

                Button {
                    showWorkedGrids.toggle()
                    if showWorkedGrids, workedGrids.isEmpty {
                        Task { await loadWorkedGrids() }
                    }
                } label: {
                    mapControlChip(
                        showWorkedGrids ? "隐藏网格" : "已通联网格",
                        image: showWorkedGrids ? "square.grid.3x3.fill" : "square.grid.3x3"
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(showWorkedGrids ? RadioPalette.transmit : Color.primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .background(.ultraThinMaterial)
    }

    private func mapControlChip(_ title: String, image: String) -> some View {
        Label(title, systemImage: image)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RadioPalette.panelRaised, in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(0.08))
            }
    }

    @ViewBuilder
    private var summaryBar: some View {
        if let payload {
            HStack(spacing: 14) {
                Label("\(payload.items.count) QSO", systemImage: "dot.radiowaves.left.and.right")
                Label("\(stations.count) 网格", systemImage: "square.grid.3x3")
                if showWorkedGrids {
                    Label("\(workedGrids.count) 已通联", systemImage: "checkmark.circle")
                }
                Spacer(minLength: 0)
                if payload.meta.limited {
                    Text("已达上限")
                        .foregroundStyle(RadioPalette.warning)
                }
            }
            .font(.caption.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.1))
            }
        }
    }

    private var requestKey: String {
        "\(logbookId):\(hours):\(limit):\(band)"
    }

    private var homeCoordinate: CLLocationCoordinate2D? {
        payload?.home.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    private var stations: [LogbookMapStation] {
        guard let payload else { return [] }
        let latestId = payload.items.max(by: { $0.startTime < $1.startTime })?.id
        let grouped = Dictionary(grouping: payload.items, by: \.grid)
        return grouped.compactMap { grid, items in
            guard let bounds = MaidenheadGrid.bounds(for: grid) else { return nil }
            return LogbookMapStation(
                grid: grid,
                latitude: bounds.centerLatitude,
                longitude: bounds.centerLongitude,
                items: items.sorted { $0.startTime > $1.startTime },
                highlighted: items.contains { $0.id == latestId }
            )
        }
        .sorted { left, right in
            if left.items.count != right.items.count { return left.items.count > right.items.count }
            return left.grid < right.grid
        }
    }

    private var routes: [LogbookMapRoute] {
        guard let home = homeCoordinate, let payload else { return [] }
        let latestId = payload.items.max(by: { $0.startTime < $1.startTime })?.id
        return payload.items.compactMap { item in
            guard let bounds = MaidenheadGrid.bounds(for: item.grid) else { return nil }
            return LogbookMapRoute(
                id: item.id,
                start: home,
                end: CLLocationCoordinate2D(
                    latitude: bounds.centerLatitude,
                    longitude: bounds.centerLongitude
                ),
                highlighted: item.id == latestId
            )
        }
    }

    private var workedGridPolygons: [LogbookWorkedGridPolygon] {
        workedGrids.prefix(500).compactMap { item in
            guard let bounds = MaidenheadGrid.bounds(for: item.grid) else { return nil }
            return LogbookWorkedGridPolygon(
                id: item.grid,
                count: item.count,
                coordinates: [
                    .init(latitude: bounds.minimumLatitude, longitude: bounds.minimumLongitude),
                    .init(latitude: bounds.minimumLatitude, longitude: bounds.maximumLongitude),
                    .init(latitude: bounds.maximumLatitude, longitude: bounds.maximumLongitude),
                    .init(latitude: bounds.maximumLatitude, longitude: bounds.minimumLongitude),
                ]
            )
        }
    }

    private func reload() async {
        loading = true
        errorMessage = nil
        do {
            payload = try await session.recentLogbookGlobe(
                logbookId: logbookId,
                hours: hours,
                limit: limit,
                operatorId: session.selectedOperatorId
            ).data
            cameraPosition = .automatic
        } catch {
            payload = nil
            errorMessage = error.localizedDescription
        }
        if showWorkedGrids {
            await loadWorkedGrids()
        }
        loading = false
    }

    private func loadWorkedGrids() async {
        do {
            workedGrids = try await session.workedLogbookGrids(
                logbookId: logbookId,
                band: band.isEmpty ? nil : band
            ).data.items
        } catch {
            workedGrids = []
            errorMessage = error.localizedDescription
        }
    }

    private static let bands = ["160m", "80m", "60m", "40m", "30m", "20m", "17m", "15m", "12m", "10m", "6m", "4m", "2m", "1.25m", "70cm", "33cm", "23cm"]
}

private struct LogbookMapStation: Identifiable {
    let grid: String
    let latitude: Double
    let longitude: Double
    let items: [LogbookRecentGlobeResponse.Payload.Item]
    let highlighted: Bool

    var id: String { grid }
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private struct LogbookMapRoute: Identifiable {
    let id: String
    let start: CLLocationCoordinate2D
    let end: CLLocationCoordinate2D
    let highlighted: Bool
}

private struct LogbookWorkedGridPolygon: Identifiable {
    let id: String
    let count: Int
    let coordinates: [CLLocationCoordinate2D]

    var fillOpacity: Double { min(0.28, 0.07 + log10(Double(max(1, count))) * 0.06) }
}

private struct LogbookMapStationDetail: View {
    @Environment(\.dismiss) private var dismiss
    let station: LogbookMapStation

    var body: some View {
        List {
            Section {
                LabeledContent("网格", value: station.grid)
                LabeledContent("坐标", value: String(format: "%.3f, %.3f", station.latitude, station.longitude))
                LabeledContent("通联数", value: String(station.items.count))
            }
            Section("QSO") {
                ForEach(station.items) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(item.callsign)
                                .font(.headline.monospaced())
                            Spacer()
                            Text(item.mode)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(RadioPalette.accent)
                        }
                        HStack {
                            Text(String(format: "%.6f MHz", item.frequency / 1_000_000))
                            Spacer()
                            Text(Self.date(item.startTime), style: .relative)
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(RadioPalette.muted)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .navigationTitle(station.grid)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
    }

    private static func date(_ timestamp: Double) -> Date {
        Date(timeIntervalSince1970: timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp)
    }
}
