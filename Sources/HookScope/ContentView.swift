import SwiftUI
import Charts
import HookCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        NavigationSplitView {
            List(selection:$model.page) {
                Section("HookScope") {
                    ForEach(Page.allCases) { page in
                        Label(page.rawValue,systemImage:page.symbol).tag(page)
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge:.bottom) {
                VStack(alignment:.leading,spacing:7) {
                    Label("数据仅存本机",systemImage:"internaldrive")
                    Text("\(model.snapshot.allTimeTotal.formatted()) 条记录").foregroundStyle(.secondary)
                }
                .font(.caption).frame(maxWidth:.infinity,alignment:.leading).padding(18)
            }
            .navigationSplitViewColumnWidth(min:180,ideal:190,max:230)
        } detail: {
            VStack(spacing:0) {
                if let notice = model.notice { NoticeBar(text:notice) { model.notice = nil } }
                switch model.page ?? .overview {
                case .overview: OverviewView(model:model)
                case .records: RecordsView(model:model)
                case .connection: ConnectionView(model:model)
                }
            }
            .navigationTitle(model.page?.rawValue ?? "概览")
            .toolbar {
                if model.page != .connection {
                    ToolbarItem {
                        Picker("时间范围",selection:$model.filter.range) {
                            ForEach(TimeRange.allCases) { Text($0.title).tag($0) }
                        }.frame(width:150).help("筛选记录的时间范围")
                    }
                    ToolbarItem {
                        Button { model.live.toggle() } label: {
                            Label(model.live ? "暂停自动刷新" : "恢复自动刷新",systemImage:model.live ? "pause" : "play")
                        }.help(model.live ? "暂停自动刷新" : "恢复自动刷新")
                    }
                    ToolbarItem {
                        Button { Task { await model.refresh() } } label: { Label("刷新",systemImage:"arrow.clockwise") }
                            .help("刷新记录 ⌘R").disabled(model.loading)
                    }
                    ToolbarItem {
                        Button { model.showInspector.toggle() } label: { Label("记录详情",systemImage:"sidebar.right") }
                            .help("显示记录详情").disabled(model.selectedRun == nil)
                    }
                }
            }
            .inspector(isPresented:$model.showInspector) {
                if let row = model.selectedRun { RunDetailView(run:row) }
            }
            .inspectorColumnWidth(min:280,ideal:310,max:380)
        }
        .onChange(of:model.page) { _,page in
            model.showInspector = false
            if page == .overview {
                model.filter.hookID = ""; model.filter.outcome = ""; model.filter.query = ""; model.filter.page = 1
            }
        }
        .onChange(of:model.filter.range) { _,_ in model.filter.page = 1 }
        .onChange(of:model.filter.hookID) { _,_ in model.filter.page = 1 }
        .onChange(of:model.filter.outcome) { _,_ in model.filter.page = 1 }
        .onChange(of:model.filter.query) { _,_ in model.filter.page = 1 }
        .task(id:model.filter) {
            do { try await Task.sleep(for:.milliseconds(180)); await model.refresh() } catch {}
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(3)) } catch { break }
                if model.live && !model.working { await model.refresh() }
            }
        }
        .alert("操作未完成",isPresented:Binding(get:{ model.error != nil },set:{ if !$0 { model.error = nil } })) {
            Button("好",role:.cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

struct OverviewView: View {
    @ObservedObject var model: AppModel
    private var issues: Int { (model.snapshot.counts[.error] ?? 0) + (model.snapshot.counts[.incomplete] ?? 0) }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                HStack(alignment:.top) {
                    VStack(alignment:.leading,spacing:6) {
                        Text("Hook 活动").font(.largeTitle.weight(.semibold))
                        Text("每次触发，一目了然。").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(model.live ? "每 3 秒刷新" : "刷新已暂停",systemImage:model.live ? "circle.fill" : "pause.circle")
                        .font(.caption).foregroundStyle(.secondary).padding(.top,9)
                }
                if model.integration?.active != true {
                    HStack(spacing:10) {
                        Image(systemName:"info.circle").foregroundStyle(.blue)
                        Text("尚未接入采集，当前显示已导入的记录。").foregroundStyle(.secondary)
                        Spacer()
                        Button("接入设置") { model.page = .connection }.buttonStyle(.link)
                    }.font(.callout)
                }
                HStack(spacing:14) {
                    MetricView(title:"触发次数",value:model.snapshot.total.formatted(),symbol:"bolt",color:.blue)
                    MetricView(title:"已拦截",value:(model.snapshot.counts[.blocked] ?? 0).formatted(),symbol:"hand.raised",color:.orange)
                    MetricView(title:"异常 / 结果缺失",value:issues.formatted(),symbol:"exclamationmark.circle",color:.red)
                    MetricView(title:"平均耗时",value:durationLabel(model.snapshot.averageMS),symbol:"stopwatch",color:.secondary)
                }
                GroupBox {
                    VStack(alignment:.leading,spacing:18) {
                        HStack {
                            Text("触发趋势").font(.headline)
                            Spacer()
                            Text(model.filter.range.title).font(.caption).foregroundStyle(.secondary)
                        }
                        if model.snapshot.total == 0 {
                            ContentUnavailableView("暂无活动",systemImage:"chart.bar",description:Text("此时间范围内没有记录。"))
                                .frame(height:190)
                        } else {
                            Chart(model.snapshot.trend) { point in
                                BarMark(x:.value("时间",point.date),y:.value("次数",point.count))
                                    .foregroundStyle(by:.value("结果",point.outcome.title))
                            }
                            .chartForegroundStyleScale(domain:Outcome.allCases.map(\.title),range:Outcome.allCases.map(\.color))
                            .chartXAxis { AxisMarks(values:.automatic(desiredCount:5)) }
                            .chartYAxis { AxisMarks(position:.leading,values:.automatic(desiredCount:4)) }
                            .chartLegend(position:.bottom,alignment:.leading,spacing:14)
                            .frame(height:190)
                            .accessibilityLabel("\(model.filter.range.title)，共触发 \(model.snapshot.total) 次，拦截 \(model.snapshot.counts[.blocked] ?? 0) 次")
                        }
                    }.padding(12)
                }
                VStack(alignment:.leading,spacing:12) {
                    HStack {
                        Text("最近记录").font(.headline)
                        Spacer()
                        Button("查看全部") { model.page = .records }.buttonStyle(.link)
                    }
                    if model.snapshot.records.isEmpty {
                        ContentUnavailableView("还没有记录",systemImage:"tray",description:Text("接入 Codex 或导入已有记录后，这里会显示最近的触发。"))
                    } else {
                        VStack(spacing:0) {
                            ForEach(Array(model.snapshot.records.prefix(6).enumerated()),id:\.element.id) { index,row in
                                Button { model.select(row.id) } label: {
                                    HStack(spacing:12) {
                                        Image(systemName:row.outcome.symbol).foregroundStyle(row.outcome.color).frame(width:22)
                                        VStack(alignment:.leading,spacing:3) {
                                            Text(row.name).fontWeight(.medium)
                                            Text(row.event.isEmpty ? "Hook" : row.event).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(row.outcome.title).foregroundStyle(row.outcome.color).frame(width:64,alignment:.leading)
                                        Text(durationLabel(row.duration)).monospacedDigit().foregroundStyle(.secondary).frame(width:76,alignment:.trailing)
                                        Text(row.started,style:.time).monospacedDigit().foregroundStyle(.secondary).frame(width:85,alignment:.trailing)
                                        Image(systemName:"chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                    }.padding(.horizontal,14).padding(.vertical,10).contentShape(Rectangle())
                                }.buttonStyle(.plain).help("查看 \(row.name) 的这次触发")
                                if index < min(5,model.snapshot.records.count-1) { Divider().padding(.leading,48) }
                            }
                        }
                        .background(.background,in:RoundedRectangle(cornerRadius:10))
                        .overlay(RoundedRectangle(cornerRadius:10).stroke(.quaternary,lineWidth:1))
                    }
                }
            }.padding(28)
        }
        .background(Color(nsColor:.windowBackgroundColor))
    }
}

struct MetricView: View {
    let title: String, value: String, symbol: String
    let color: Color
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Label(title,systemImage:symbol).font(.subheadline).foregroundStyle(color)
            Text(value).font(.system(size:28,weight:.semibold,design:.rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth:.infinity,alignment:.leading).padding(18)
        .background(.background,in:RoundedRectangle(cornerRadius:12))
        .overlay(RoundedRectangle(cornerRadius:12).stroke(.quaternary,lineWidth:1))
    }
}

struct RecordsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                Picker("Hook",selection:$model.filter.hookID) {
                    Text("全部 Hooks").tag("")
                    ForEach(model.snapshot.hookIDs,id:\.self) { Text(HookNames.name($0)).tag($0) }
                }.labelsHidden().frame(width:170)
                Picker("结果",selection:$model.filter.outcome) {
                    Text("全部结果").tag("")
                    ForEach(Outcome.allCases) { Text($0.title).tag($0.rawValue) }
                }.labelsHidden().frame(width:135)
                Spacer(minLength:12)
                HStack(spacing:6) {
                    Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索目录、会话或原因",text:$model.filter.query).textFieldStyle(.plain)
                    if !model.filter.query.isEmpty {
                        Button { model.filter.query = "" } label: { Image(systemName:"xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary).help("清除搜索")
                    }
                }.padding(7).background(.quaternary.opacity(0.35),in:RoundedRectangle(cornerRadius:6)).frame(maxWidth:290)
            }.padding(16)
            Divider()
            Table(model.snapshot.records,selection:Binding(get:{ model.selectedID },set:{ model.select($0) })) {
                TableColumn("时间") { row in
                    VStack(alignment:.leading,spacing:2) {
                        Text(row.started,format:.dateTime.hour().minute().second()).monospacedDigit()
                        Text(row.started,format:.dateTime.month().day()).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical,3)
                }.width(min:85,ideal:105,max:140)
                TableColumn("Hook") { Text($0.name) }.width(min:110,ideal:150)
                TableColumn("结果") { row in Label(row.outcome.title,systemImage:row.outcome.symbol).foregroundStyle(row.outcome.color) }.width(min:92,ideal:105,max:125)
                TableColumn("耗时") { Text(durationLabel($0.duration)).monospacedDigit().foregroundStyle(.secondary) }.width(min:70,ideal:85,max:100)
                TableColumn("目录 / 原因") { row in
                    Text(row.reason.isEmpty ? (row.directory.isEmpty ? "—" : row.directory) : row.reason)
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).help(row.reason.isEmpty ? row.directory : row.reason)
                }.width(min:160,ideal:280)
            }
            .overlay {
                if model.snapshot.records.isEmpty {
                    ContentUnavailableView("没有匹配的记录",systemImage:"line.3.horizontal.decrease.circle",description:Text("尝试调整时间范围或筛选条件。"))
                }
            }
            Divider()
            HStack {
                Text("\(model.snapshot.total.formatted()) 条记录").foregroundStyle(.secondary)
                Spacer()
                Text("第 \(model.snapshot.page) / \(model.snapshot.pages) 页").monospacedDigit().foregroundStyle(.secondary)
                Button { model.filter.page = max(1,model.snapshot.page-1) } label: { Image(systemName:"chevron.left") }.disabled(model.snapshot.page <= 1).help("上一页")
                Button { model.filter.page = model.snapshot.page+1 } label: { Image(systemName:"chevron.right") }.disabled(model.snapshot.page >= model.snapshot.pages).help("下一页")
            }.font(.caption).padding(12)
        }
    }
}

struct RunDetailView: View {
    let run: HookRun
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                VStack(alignment:.leading,spacing:10) {
                    Label(run.outcome.title,systemImage:run.outcome.symbol).foregroundStyle(run.outcome.color).font(.headline)
                    Text(run.name).font(.title2.weight(.semibold))
                    Text(run.started,format:.dateTime.year().month().day().hour().minute().second()).foregroundStyle(.secondary)
                }
                Divider()
                field("触发事件",run.event)
                HStack(alignment:.top) { field("耗时",durationLabel(run.duration)); Spacer(); field("退出码",run.exitCode.map(String.init) ?? "—") }
                if !run.reason.isEmpty { field("原因",run.reason) }
                if run.outcome == .incomplete && run.exitCode == nil {
                    Text("记录超过 15 秒仍无完成结果。可能是取消、进程中断或写入失败，不能据此判断是否通过。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Divider()
                field("工作目录",run.directory)
                field("工具",run.tool)
                field("会话",run.session,mono:true)
                field("轮次",run.turn,mono:true)
                Text("只保存运行元数据，不保存提示词、完整命令或原始输出。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(22).textSelection(.enabled)
        }
    }
    private func field(_ title: String,_ value: String,mono: Bool = false) -> some View {
        VStack(alignment:.leading,spacing:6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value).font(mono ? .system(.caption,design:.monospaced) : .body).fixedSize(horizontal:false,vertical:true)
        }
    }
}

struct NoticeBar: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment:.top,spacing:10) {
            Image(systemName:"info.circle").foregroundStyle(.blue)
            Text(text).font(.callout)
            Spacer()
            Button(action:dismiss) { Image(systemName:"xmark") }.buttonStyle(.plain).help("关闭提示")
        }.padding(14).frame(maxWidth:.infinity).background(Color.accentColor.opacity(0.08))
    }
}
