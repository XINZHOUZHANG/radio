import SwiftUI
import UIKit

struct FT8View: View {
    @EnvironmentObject private var session: TX5DRSession
    @EnvironmentObject private var radio: RadioWebSocket
    @State private var callsign = ""
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            controlHeader
            Divider().opacity(0.25)
            decodedList
        }
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle("FT8 / FT4")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { radio.clearDecodedFrames() } label: {
                    Image(systemName: "trash")
                }
                .disabled(radio.decodedFrames.isEmpty)
            }
        }
    }

    private var controlHeader: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.selectedOperator?.myCallsign ?? "未选择操作员")
                        .font(.headline)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(operatorActive ? RadioPalette.accent : RadioPalette.muted)
                            .frame(width: 7, height: 7)
                        Text(operatorActive ? "操作员运行中" : "操作员已停止")
                            .font(.caption)
                            .foregroundStyle(RadioPalette.muted)
                    }
                }
                Spacer()
                Button(operatorActive ? "停止" : "启动") {
                    session.setOperatorRunning(!operatorActive)
                }
                .buttonStyle(RadioActionButtonStyle(tint: operatorActive ? RadioPalette.warning : RadioPalette.accent))
            }

            HStack(spacing: 8) {
                TextField("目标呼号", text: $callsign)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(RadioPalette.panelRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button("呼叫") {
                    session.requestFT8Call(callsign)
                    callsign = ""
                }
                .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.accent, prominent: true))
            }

            HStack {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(RadioPalette.muted)
                TextField("筛选解码消息", text: $filter)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.subheadline)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RadioPalette.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(14)
    }

    private var decodedList: some View {
        Group {
            if filteredFrames.isEmpty {
                ContentUnavailableView(
                    "等待数字模式解码",
                    systemImage: "waveform.path.ecg",
                    description: Text("启动操作员后，TX-5DR 的时隙解码会实时显示在这里。")
                )
            } else {
                List(filteredFrames) { frame in
                    Button {
                        if let candidate = candidateCallsign(in: frame.message) {
                            callsign = candidate
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Text(String(format: "%+.0f", frame.snr))
                                .font(.system(.subheadline, design: .monospaced).weight(.bold))
                                .foregroundStyle(frame.snr >= 0 ? RadioPalette.accent : RadioPalette.cyan)
                                .frame(width: 38, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(frame.message)
                                    .font(.system(.body, design: .monospaced).weight(.medium))
                                    .foregroundStyle(Color.white)
                                HStack(spacing: 12) {
                                    Text(String(format: "DT %+.1f", frame.dt))
                                    Text(String(format: "%.0f Hz", frame.freq))
                                    if let operatorId = frame.operatorId {
                                        Text(operatorId)
                                    }
                                }
                                .font(.caption2.monospaced())
                                .foregroundStyle(RadioPalette.muted)
                            }
                            Spacer()
                            Image(systemName: "scope")
                                .foregroundStyle(RadioPalette.muted)
                        }
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(RadioPalette.panel)
                    .contextMenu {
                        if let candidate = candidateCallsign(in: frame.message) {
                            Button("呼叫 \(candidate)") { session.requestFT8Call(candidate) }
                        }
                        Button("复制消息") { UIPasteboard.general.string = frame.message }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var selectedStatus: JSONValue? {
        guard let id = session.selectedOperatorId else { return nil }
        return radio.operatorStatuses[id]
    }

    private var operatorActive: Bool { selectedStatus?["isActive"]?.boolValue ?? false }

    private var filteredFrames: [FrameMessage] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !query.isEmpty else { return radio.decodedFrames }
        return radio.decodedFrames.filter { $0.message.uppercased().contains(query) }
    }

    private func candidateCallsign(in message: String) -> String? {
        message
            .uppercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .first { token in
                (3...10).contains(token.count)
                    && token.contains(where: \.isNumber)
                    && token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "/" }
            }
    }
}
