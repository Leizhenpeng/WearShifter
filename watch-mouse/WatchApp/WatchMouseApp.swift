import SwiftUI
import WatchMouseCore

@main
struct WatchMouseApp: App {
    @StateObject private var controller = WatchController()
    #if DEBUG
    @StateObject private var capture = CaptureController()
    #endif
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView(controller: controller)
                #if DEBUG
                CaptureListView(capture: capture, cursor: controller)
                #endif
            }
            .tabViewStyle(.verticalPage)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { controller.appBecameActive() }
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var controller: WatchController

    var body: some View {
        VStack(spacing: 8) {
            Text(controller.linkText)
                .font(.footnote)
                .multilineTextAlignment(.center)
            Button(controller.isRunning ? "暂停光标" : "开始光标") {
                controller.toggle()
            }
            .tint(controller.isRunning ? .orange : .green)
            // 双指互点开关，手举着也能暂停，不用另一只手碰屏幕。
            .handGestureShortcut(.primaryAction)
            .disabled(!controller.isConnected && !controller.isRunning)
            Text(controller.detailText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

// 采集只用于开发验证，不进 TestFlight 版本。
#if DEBUG
struct CaptureListView: View {
    @ObservedObject var capture: CaptureController
    @ObservedObject var cursor: WatchController

    var body: some View {
        if let run = capture.activeRun {
            CaptureRunView(capture: capture, run: run)
        } else {
            List {
                if let error = capture.errorText {
                    Text(error).font(.caption2).foregroundStyle(.orange)
                }
                ForEach(CaptureRun.plan) { run in
                    Button {
                        cursor.stopIfRunning()
                        capture.start(run)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(run.title)
                            Text(run.instruction).font(.caption2).foregroundStyle(.secondary)
                            if let done = capture.completedCounts[run.id] {
                                Text("已录 \(done) 轮").font(.caption2).foregroundStyle(.green)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct CaptureRunView: View {
    @ObservedObject var capture: CaptureController
    let run: CaptureRun

    var body: some View {
        VStack(spacing: 6) {
            Text(run.title).font(.headline)
            Text(capture.progressText).font(.title3.monospacedDigit())
            Text(run.instruction)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                if case .cued = run.kind {
                    Button("作废") { capture.markLastInvalid() }.tint(.orange)
                }
                Button("结束") { capture.finish() }
            }
        }
    }
}
#endif
