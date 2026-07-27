import SwiftUI

func note(_ s: String) { print(s); fflush(stdout) }

struct Row: Identifiable { let id: String; let text: String }

struct Probe: View {
    @State private var rows: [Row] = (0..<10).map { Row(id: "r\($0)", text: "row \($0)") }
    @State private var eager = true
    @State private var offset: CGFloat = 0
    @State private var phase = "init"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if eager {
                    VStack(alignment: .leading, spacing: 8) { content }.padding(16)
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) { content }.padding(16)
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { g in g.contentOffset.y } action: { _, y in
                offset = y
            }
            .task {
                try? await Task.sleep(for: .milliseconds(600))
                proxy.scrollTo("bottom", anchor: .bottom)
                try? await Task.sleep(for: .milliseconds(400))
                note("A. after scroll-to-bottom (eager, 10 rows): offset=\(Int(offset))")

                // 场景 1：容器类型切换（模拟 turns.count 跨过 12 的那一刻）
                phase = "swap"; eager = false
                try? await Task.sleep(for: .milliseconds(600))
                note("B. after container swap VStack->LazyVStack: offset=\(Int(offset))")

                // 复位到底部，再测场景 2
                proxy.scrollTo("bottom", anchor: .bottom)
                try? await Task.sleep(for: .milliseconds(400))
                note("C. re-pinned to bottom (lazy): offset=\(Int(offset))")

                // 场景 2：顶部插入 20 行（模拟节点补齐 / 加载更早）
                rows = (100..<120).map { Row(id: "old\($0)", text: "older \($0)") } + rows
                try? await Task.sleep(for: .milliseconds(600))
                note("D. after prepending 20 rows (lazy): offset=\(Int(offset))")

                // 场景 3：整体替换 rows（模拟磁盘缓存 -> 网络结果）
                proxy.scrollTo("bottom", anchor: .bottom)
                try? await Task.sleep(for: .milliseconds(400))
                let before = offset
                rows = (0..<40).map { Row(id: "n\($0)", text: "new \($0)") }
                try? await Task.sleep(for: .milliseconds(600))
                note("E. wholesale rows replace: before=\(Int(before)) after=\(Int(offset))")
                note("DONE")
                exit(0)
            }
        }
        .frame(width: 500, height: 400)
    }

    @ViewBuilder private var content: some View {
        ForEach(rows) { r in
            Text(r.text).frame(height: 60).frame(maxWidth: .infinity, alignment: .leading).id(r.id)
        }
        Color.clear.frame(height: 1).id("bottom")
    }
}

@main struct App0: App {
    var body: some Scene { WindowGroup { Probe() } }
}
