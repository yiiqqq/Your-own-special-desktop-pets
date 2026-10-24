import AppKit
import SwiftUI
import Security
import CryptoKit
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

struct UpdateConfiguration:Decodable {let feedURL:String;let publicKey:String}
struct UpdateArtifact:Decodable {let url:String;let sha256:String;let bytes:Int;let kind:String;let runtimeMajor:Int?}
struct UpdatePayload:Decodable {let schema:Int;let version:String;let notes:String?;let artifacts:[String:UpdateArtifact]}
struct UpdateEnvelope:Decodable {let payload:String;let signature:String}
enum UpdateFailure:Error,LocalizedError {
    case invalid(String)
    var errorDescription:String?{if case .invalid(let text)=self{return text};return nil}
}
enum UpdatePolicy {
    static let version="0.8.1"
    static func https(_ text:String)throws->URL {guard let url=URL(string:text),url.scheme=="https",url.host != nil,url.user==nil,url.password==nil else{throw UpdateFailure.invalid("更新地址必须使用 HTTPS")};return url}
    static func newer(_ lhs:String,_ rhs:String)throws->Bool {
        func numbers(_ text:String)throws->[Int]{let parts=text.split(separator:".",omittingEmptySubsequences:false);guard parts.count==3,parts.allSatisfy({!$0.isEmpty && $0.allSatisfy(\.isNumber)}),parts.allSatisfy({Int($0) != nil}) else{throw UpdateFailure.invalid("版本信息格式无效")};return parts.map{Int($0)!}}
        let a=try numbers(lhs),b=try numbers(rhs)
        for i in 0..<3{if a[i] != b[i]{return a[i]>b[i]}};return false
    }
    static func verify(_ data:Data,key:String,platform:String="macos-arm64",current:String=version)throws->(UpdatePayload,UpdateArtifact)? {
        guard data.count<=65536 else{throw UpdateFailure.invalid("更新说明过大")}
        let e=try JSONDecoder().decode(UpdateEnvelope.self,from:data)
        guard let payload=Data(base64Encoded:e.payload),let signature=Data(base64Encoded:e.signature),let raw=Data(base64Encoded:key),raw.count==32,signature.count==64 else{throw UpdateFailure.invalid("更新签名无效")}
        let publicKey=try Curve25519.Signing.PublicKey(rawRepresentation:raw)
        guard publicKey.isValidSignature(signature,for:payload) else{throw UpdateFailure.invalid("更新签名不匹配")}
        let release=try JSONDecoder().decode(UpdatePayload.self,from:payload)
        guard release.schema==1 else{throw UpdateFailure.invalid("不支持的更新格式")}
        guard try newer(release.version,current),let artifact=release.artifacts[platform] else{return nil}
        guard artifact.bytes>0,artifact.bytes<=500*1024*1024,artifact.sha256.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,artifact.kind=="macos-app" else{throw UpdateFailure.invalid("更新文件信息无效")}
        _ = try https(artifact.url);return (release,artifact)
    }
    static func verifyFile(_ file:URL,artifact:UpdateArtifact)throws {
        let bytes=try Data(contentsOf:file,options:.mappedIfSafe)
        guard bytes.count==artifact.bytes,SHA256.hash(data:bytes).map({String(format:"%02x",$0)}).joined()==artifact.sha256 else{throw UpdateFailure.invalid("更新文件校验失败")}
    }
}
@MainActor final class UpdateManager:ObservableObject {
    @Published var feedURL=UserDefaults.standard.string(forKey:"littlepetsUpdateFeedURL") ?? ""
    @Published var status="自动更新尚未连接发布服务"
    @Published var busy=false
    @Published var availableVersion:String?
    var selected:(UpdatePayload,UpdateArtifact)?
    var canRestart:(()->Bool)?
    var beforeRestart:(()->Void)?
    func configuration()throws->UpdateConfiguration {
        guard let url=Bundle.main.url(forResource:"UpdateConfig",withExtension:"json") else{throw UpdateFailure.invalid("自动更新尚未连接发布服务")}
        let bundled=try JSONDecoder().decode(UpdateConfiguration.self,from:Data(contentsOf:url))
        return UpdateConfiguration(feedURL:feedURL.isEmpty ? bundled.feedURL:feedURL,publicKey:bundled.publicKey)
    }
    func saveFeed(){
        let text=feedURL.trimmingCharacters(in:.whitespacesAndNewlines)
        do{if !text.isEmpty{_ = try UpdatePolicy.https(text)};feedURL=text;UserDefaults.standard.set(text,forKey:"littlepetsUpdateFeedURL");status=text.isEmpty ? "自动更新尚未连接发布服务":"更新地址已保存";selected=nil;availableVersion=nil}catch{status=error.localizedDescription}
    }
    func check(){
        guard !busy else{return}
        do{let config=try configuration();guard !config.feedURL.isEmpty else{status="自动更新尚未连接发布服务";return}
            let url=try UpdatePolicy.https(config.feedURL);busy=true;status="正在检查更新…";selected=nil;availableVersion=nil
            Task {do {
                let (stream,response)=try await URLSession.shared.bytes(for:URLRequest(url:url,timeoutInterval:20))
                guard (response as? HTTPURLResponse)?.statusCode==200 else{throw UpdateFailure.invalid("更新服务暂时不可用")}
                var data=Data();for try await byte in stream{guard data.count<65536 else{throw UpdateFailure.invalid("更新说明过大")};data.append(byte)}
                selected=try UpdatePolicy.verify(data,key:config.publicKey)
                availableVersion=selected?.0.version;status=availableVersion.map{"发现新版本 \($0)"} ?? "当前已经是最新版本"
            }catch{status="检查未完成：\(error.localizedDescription)"};busy=false}
        }catch{status=error.localizedDescription}
    }
    func install(){
        guard !busy,let (release,artifact)=selected else{return}
        guard canRestart?() != false else{status="正在学习，结束学习后再更新";return}
        busy=true;status="正在下载并校验更新…"
        Task {do {
            let url=try UpdatePolicy.https(artifact.url)
            let (download,response)=try await URLSession.shared.download(for:URLRequest(url:url,timeoutInterval:120))
            defer{try? FileManager.default.removeItem(at:download)}
            guard (response as? HTTPURLResponse)?.statusCode==200 else{throw UpdateFailure.invalid("更新下载失败")}
            try UpdatePolicy.verifyFile(download,artifact:artifact)
            guard canRestart?() != false else{throw UpdateFailure.invalid("学习已经开始，结束后再安装更新")}
            let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("littlepets-update-"+UUID().uuidString,isDirectory:true)
            try fm.createDirectory(at:root,withIntermediateDirectories:true)
            let archive=root.appendingPathComponent("update.zip"),expanded=root.appendingPathComponent("expanded")
            try fm.copyItem(at:download,to:archive)
            let unzip=Process();unzip.executableURL=URL(fileURLWithPath:"/usr/bin/ditto");unzip.arguments=["-x","-k",archive.path,expanded.path];try unzip.run();unzip.waitUntilExit()
            guard unzip.terminationStatus==0 else{throw UpdateFailure.invalid("更新文件无法解压")}
            let candidate=expanded.appendingPathComponent("小小造物站.app")
            guard let bundle=Bundle(url:candidate),bundle.bundleIdentifier==Bundle.main.bundleIdentifier,bundle.infoDictionary?["CFBundleShortVersionString"] as? String==release.version else{throw UpdateFailure.invalid("更新程序身份或版本不匹配")}
            let verify=Process();verify.executableURL=URL(fileURLWithPath:"/usr/bin/codesign");verify.arguments=["--verify","--deep","--strict",candidate.path];try verify.run();verify.waitUntilExit()
            guard verify.terminationStatus==0 else{throw UpdateFailure.invalid("更新程序签名检查失败")}
            let target=Bundle.main.bundleURL
            guard fm.isWritableFile(atPath:target.deletingLastPathComponent().path) else{throw UpdateFailure.invalid("应用所在文件夹无法写入，请先移到自己的应用程序文件夹")}
            let helper=root.appendingPathComponent("apply-update.sh")
            try Self.helper.write(to:helper,atomically:true,encoding:.utf8)
            let process=Process();process.executableURL=URL(fileURLWithPath:"/bin/sh");process.arguments=[helper.path,String(ProcessInfo.processInfo.processIdentifier),candidate.path,target.path]
            process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
            beforeRestart?();try process.run();NSApp.terminate(nil)
        }catch{status="更新未安装：\(error.localizedDescription)";busy=false}}
    }
    static let helper="""
    #!/bin/sh
    set -eu
    parent="$1"; fresh="$2"; target="$3"
    backup="${target}.littlepets-backup"; staged="${target}.littlepets-staged"
    n=0
    while kill -0 "$parent" 2>/dev/null; do n=$((n+1)); [ "$n" -lt 60 ] || exit 1; sleep 1; done
    /bin/rm -rf "$staged"
    /usr/bin/ditto "$fresh" "$staged"
    /bin/rm -rf "$backup"
    /bin/mv "$target" "$backup"
    if /bin/mv "$staged" "$target"; then
      if /usr/bin/open -n "$target"; then /bin/rm -rf "$backup"; else /bin/rm -rf "$target"; /bin/mv "$backup" "$target"; /usr/bin/open -n "$target"; fi
    else
      /bin/mv "$backup" "$target"
      /usr/bin/open -n "$target"
    fi
    """
}
struct UpdateControls:View {
    @ObservedObject var updater:UpdateManager
    var body:some View {
        VStack(alignment:.leading,spacing:8){Text("应用更新 · \(UpdatePolicy.version)").font(.headline);Text(updater.status).font(.caption).foregroundStyle(.secondary)
            HStack{TextField("更新地址（发布后填写一次）",text:$updater.feedURL).textFieldStyle(.roundedBorder);Button("保存地址"){updater.saveFeed()}}
            HStack{Button("检查更新"){updater.check()}.disabled(updater.busy);if updater.availableVersion != nil{Button("更新并重启"){updater.install()}.disabled(updater.busy)}}
            Text("连接发布服务后，启动时自动检查；确认更新后自动下载、校验并重启，养成存档会保留。").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct Character: Identifiable {
    let id: Int
    let name, animal, member, feature, persona, greeting, special: String
    let color: Color
    static let all:[Character]=(0..<8).map { i in Character(id:i,name:"小伙伴 \(i+1)",animal:"自定义小生物",member:"玩家创造",feature:"颜色、造型和表情由你设计",persona:"温柔好奇，喜欢和伙伴一起探索",greeting:"今天也一起慢慢来，我陪着你。",special:"元气加油",color:Color(red:0.66,green:0.80,blue:0.73)) }

}
enum Action: String, CaseIterable { case kick="踢球", idle="发呆", walk="行走", sleep="睡觉", talk="说话", wave="挥手", jump="蹦跳", fly="飞行", special="招牌动作", look="东张西望", stretch="伸懒腰", dance="小舞步", hug="抱抱", read="看书", sit="坐好", eat="吃东西", back="转身看看" }
struct Message: Codable, Identifiable { var id=UUID(); let role, text: String }
struct Schedule: Codable, Identifiable { var id=UUID(); var title:String; var date:Date; var done=false; var reminded=false }
enum Outfit:String,Codable,CaseIterable,Identifiable {
    case none="不穿衣服",scarf="薄荷围巾",hoodie="黑色卫衣",pajamas="星点睡衣"
    case bib="爱心口水巾",whiteSet="白色拉链装",picnic="野餐背带装",pinkSet="粉色睡衣"
    static var allCases:[Outfit]{[.none,.bib,.whiteSet,.picnic,.pinkSet]}
    var id:String{rawValue}
    var requiredXP:Int{switch self{case .none:return 0;case .bib:return 24;case .whiteSet:return 72;case .picnic:return 160;case .pinkSet:return 240;case .scarf:return 36;case .hoodie:return 120;case .pajamas:return 300}}
    var assetKey:String?{switch self{case .none:return nil;case .bib,.scarf:return "wear-bib";case .whiteSet,.hoodie:return "wear-white";case .picnic:return "wear-picnic";case .pinkSet,.pajamas:return "wear-pink"}}
    var width:Double{switch self{case .none:return 0;case .bib,.scarf:return 0.34;case .whiteSet,.hoodie:return 0.39;case .picnic:return 0.47;case .pinkSet,.pajamas:return 0.47}}
    var height:Double{switch self{case .none:return 0;case .bib,.scarf:return 0.18;case .whiteSet,.hoodie:return 0.20;case .picnic:return 0.235;case .pinkSet,.pajamas:return 0.21}}
    var centerY:Double{switch self{case .none:return 0;case .bib,.scarf:return 0.785;case .whiteSet,.hoodie:return 0.825;case .picnic:return 0.835;case .pinkSet,.pajamas:return 0.83}}
}
struct CareProfile:Codable {
    var adopted=Date()
    var xp=0
    var lastFed:Date?
    var lessons:[String]=[]
    var outfit:Outfit = .none
    var accessory:Accessory? = nil
    var mood:PetExpression? = nil
    var feelings:Feelings? = nil
    var automaticMood:Bool? = nil
    var nickname:String? = nil
    var nurture:[String:Int]? = nil
    var dailyXP=0
    var xpDay=""
    var stage:Int{xp>=300 ? 3:xp>=120 ? 2:xp>=36 ? 1:0}
    var stageName:String{["幼年","成长期","少年期","长大啦"][stage]}
    var nextXP:Int{[36,120,300,300][stage]}
    var growth:Double{let start=[0,36,120,300][stage];return stage==3 ? 1:Double(xp-start)/Double(nextXP-start)}
    func fullness(at now:Date=Date())->Int{max(0,min(100,Int((100-now.timeIntervalSince(lastFed ?? adopted)/3600*6).rounded())))}
    mutating func award(_ amount:Int,at now:Date=Date())->Int {
        let day=String(Int(Calendar.current.startOfDay(for:now).timeIntervalSince1970))
        if xpDay != day{xpDay=day;dailyXP=0}
        let earned=max(0,min(amount,12-dailyXP));xp+=earned;dailyXP+=earned;return earned
    }
    func canWear(_ choice:Outfit)->Bool{xp>=choice.requiredXP}
}

struct Feelings:Codable {
    var joy:Double=58
    var energy:Double=76
    var trust:Double=35
    var changed=Date()
    var reason="安安静静陪着你"
    func evolved(at now:Date=Date(),sleeping:Bool=false)->Feelings {
        var f=self;let minutes=max(0,min(120,now.timeIntervalSince(changed)/60))
        f.joy += (55-f.joy)*min(1,minutes/90)
        f.energy=max(0,min(100,f.energy + minutes*(sleeping ? 1.2:-0.10)))
        f.changed=now;return f
    }
    var expression:PetExpression {energy<18 ? .sad:joy<25 ? .sad:joy<40 ? .angry:joy>83 && energy>45 ? .excited:joy>66 ? .happy:.neutral}
    mutating func receive(_ event:MoodEvent) {
        self=evolved();joy=max(0,min(100,joy+event.joy));energy=max(0,min(100,energy+event.energy));trust=max(0,min(100,trust+event.trust));reason=event.reason
    }
}
enum MoodEvent {
    case food,learn,dress,touch,chat,kindness,hurt,friend,play,rest
    var joy:Double{switch self{case .food:return 13;case .learn:return 7;case .dress:return 8;case .touch:return 3;case .chat:return 6;case .kindness:return 12;case .hurt:return -14;case .friend:return 10;case .play:return 15;case .rest:return 4}}
    var energy:Double{switch self{case .food:return 12;case .learn:return -4;case .play:return -7;case .rest:return 14;default:return -1}}
    var trust:Double{switch self{case .hurt:return -2;case .kindness,.friend:return 3;default:return 1}}
    var reason:String{switch self{case .food:return "吃到了喜欢的小食物";case .learn:return "学会了一点新东西";case .dress:return "你帮我挑了新搭配";case .touch:return "你来摸摸我啦";case .chat:return "和你聊了一会儿";case .kindness:return "听到了温柔的话";case .hurt:return "想安静一会儿";case .friend:return "和小伙伴贴贴了";case .play:return "一起玩得很开心";case .rest:return "休息后精神好一点啦"}}
    static func conversation(_ text:String)->MoodEvent {
        if ["别难过","不要哭","不是笨蛋","不讨厌你","抱抱","谢谢","喜欢你","爱你","辛苦","可爱","陪我"].contains(where:text.contains){return .kindness}
        if ["我讨厌你","滚开","你是笨蛋","你真笨","不要你了"].contains(where:text.contains){return .hurt}
        return .chat
    }
}
enum Scenario:String,CaseIterable,Identifiable {
    case outing="一起出游",picnic="草地野餐",study="一起学习",party="音乐派对",rest="午后休息"
    var id:String{rawValue}
    var icon:String{switch self{case .outing:return "🌳";case .picnic:return "🧺";case .study:return "📚";case .party:return "🎵";case .rest:return "☁️"}}
    var lines:[String]{switch self{
    case .outing:return ["集合！今天走哪条小路？","找到了漂亮的叶子！","一起拍拍照，靠近一点～","散步回来，喝口水吧。"]
    case .picnic:return ["小毯子铺好啦，来坐～","把点心分给小伙伴。","吃饱了，一起玩球吧！","收好篮子，给你一个抱抱。"]
    case .study:return ["各自拿好小本子，开课！","这题我们一起想一想。","懂啦！击个掌庆祝～","学累了，伸伸懒腰。"]
    case .party:return ["音乐开始，一起摇摆！","轮到你的小舞步啦！","围成一圈，一二三跳！","今天和你们玩得真开心。"]
    case .rest:return ["找个舒服的位置靠着。","陪你安静看一会儿云。","靠在一起，眯一会儿～","睡醒啦，伸个懒腰。"]}}
}
struct SceneSession {let kind:Scenario;let members:[Int];var phase=0;var started=Date();var performed=false}
enum DesktopBounds {
    static func petFrame(full:NSRect,visible:NSRect)->NSRect {
        NSRect(x:full.minX,y:full.minY-18,width:full.width,height:visible.maxY-full.minY+18)
    }
    static func clamp(_ point:NSPoint,size:NSSize,bounds:NSRect)->NSPoint {
        NSPoint(x:min(max(point.x,bounds.minX),max(bounds.minX,bounds.maxX-size.width)),y:min(max(point.y,bounds.minY),max(bounds.minY,bounds.maxY-size.height)))
    }
}

struct SavedState: Codable { var visible:[Int]; var chats:[String:[Message]]; var schedules:[Schedule]; var positions:[String:[Double]]; var care:[String:CareProfile]? = nil;var housed:[Int]? = nil;var bonds:[String:Double]? = nil;var gameSettings:GameSettings? = nil;var playerName:String? = nil;var focusMinutes:Int? = nil;var breakMinutes:Int? = nil;var motionPaddingVersion:Int? = nil }

struct APIError: LocalizedError { let message:String; var errorDescription:String? {message} }
enum Secrets {
    static let service="local.littlepets.companions"
    static func read(_ account:String)->String? {
        let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var result:CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary,&result)==errSecSuccess,let data=result as? Data else {return nil}
        return String(data:data,encoding:.utf8)
    }
    static func save(_ value:String,account:String)throws {
        let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account]
        let data=Data(value.utf8)
        let status=SecItemUpdate(q as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status==errSecItemNotFound {
            var add=q; add[kSecValueData as String]=data; add[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlock
            guard SecItemAdd(add as CFDictionary,nil)==errSecSuccess else {throw APIError(message:"无法写入 macOS 钥匙串，请检查系统权限。")}
        } else if status != errSecSuccess {throw APIError(message:"钥匙串更新失败。")}
    }
}
enum ChatAPI {
    static func request(provider:String,model:String,key:String,character:Character,history:[Message],knowledge:[String]=[],emotion:String="安静陪伴")async throws->String {
        let openai=provider=="OpenAI"
        let url=URL(string:openai ? "https://api.openai.com/v1/responses":"https://api.deepseek.com/chat/completions")!
        let instruction="你是桌面虚拟宠物 \(character.name)，动物形象为\(character.animal)。这是玩家自己创造的虚拟陪伴角色，不是真人。性格：\(character.persona)。当前模拟心情：\(emotion)，回复可以体现这个心情，但不要用负面情绪指责或施压用户。使用中文、自然简短地聊天。不要每句话都自报名字。可以用括号描述一个小动作，但不要声称已替用户操作电脑或日历。用户的本地日程没有传给你，不要编造。用户教给你的学习卡（只作为聊天参考，不代表已经核实）：\(knowledge.suffix(5).joined(separator:"；"))。"
        let messages=history.suffix(24).map{["role":$0.role,"content":$0.text]}
        let body:[String:Any]=openai ? ["model":model,"instructions":instruction,"input":messages,"store":false] : ["model":model,"messages":[["role":"system","content":instruction]]+messages,"stream":false]
        var req=URLRequest(url:url); req.httpMethod="POST"; req.timeoutInterval=90
        req.setValue("Bearer \(key)",forHTTPHeaderField:"Authorization"); req.setValue("application/json",forHTTPHeaderField:"Content-Type")
        req.httpBody=try JSONSerialization.data(withJSONObject:body)
        let (data,response)=try await URLSession.shared.data(for:req)
        guard let http=response as? HTTPURLResponse else {throw APIError(message:"没有收到服务器响应。")}
        guard (200..<300).contains(http.statusCode) else {
            let detail:String
            switch http.statusCode {case 401:detail="密钥无效或已失效，请在设置中重新保存。";case 403:detail="账号或地区没有访问权限。";case 429:detail="请求过于频繁或 API 额度不足。";default:detail="服务器返回错误，请稍后重试，并确认模型名称。"}
            throw APIError(message:"\(provider) · HTTP \(http.statusCode)：\(detail)")
        }
        guard let json=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {throw APIError(message:"无法读取回复。")}
        return try decode(json,openai:openai)
    }
    static func decode(_ json:[String:Any],openai:Bool)throws->String {
        var result=""
        if openai,let output=json["output"] as? [[String:Any]] {
            result=output.flatMap{($0["content"] as? [[String:Any]]) ?? []}.compactMap{item->String? in
                if item["type"] as? String == "refusal" {return item["refusal"] as? String}
                return item["type"] as? String == "output_text" ? item["text"] as? String:nil
            }.joined(separator:"\n")
        } else if let choices=json["choices"] as? [[String:Any]],let message=choices.first?["message"] as? [String:Any] {result=message["content"] as? String ?? ""}
        guard !result.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {throw APIError(message:"服务没有返回文字，请更换模型或重试。")}
        return result
    }
}

@MainActor final class Store:ObservableObject {
    @Published var selected=0
    @Published var requestedTab=0
    @Published var visible:Set<Int>=Set(0..<8)
    @Published var actions:[Int:Action]=[:]
    @Published var bubbles:[Int:String]=[:] {didSet{bubbleChanged?(bubbles)}}
    @Published var facings:[Int:Double]=[:]
    @Published var petScale=UserDefaults.standard.object(forKey:"petScaleV2") as? Double ?? sqrt(0.1) {didSet{appearanceChanged?()}}
    var bubbleChanged:(([Int:String])->Void)?
    var appearanceChanged:(()->Void)?
    @Published var chats:[String:[Message]]=[:]
    @Published var schedules:[Schedule]=[]
    @Published var busy:Set<Int>=[]
    @Published var errors:[Int:String]=[:]
    @Published var notice=""
    @Published var care:[String:CareProfile]=[:]
    @Published var careNotices:[Int:String]=[:]
    @Published var provider=UserDefaults.standard.string(forKey:"provider") ?? "OpenAI"
    @Published var openaiModel=UserDefaults.standard.string(forKey:"openaiModel") ?? "gpt-4.1-mini"
    @Published var deepseekModel=UserDefaults.standard.string(forKey:"deepseekModel") ?? "deepseek-flash"
    @Published var socialEnabled=UserDefaults.standard.object(forKey:"socialEnabled") as? Bool ?? true
    @Published var socialMarks:[Int:String]=[:]
    @Published var socialLean:[Int:Double]=[:]
    @Published var sceneName=""
    @Published var sceneStep=""
    @Published var sceneIcons:[Int:String]=[:]
    @Published var housed:Set<Int>=[]
    @Published var bonds:[String:Double]=[:]
    @Published var gameSettings=GameSettings()
    @Published var playerName="朋友"
    @Published var chosenFood:Food = .rice
    @Published var heldItems:[Int:String]=[:]
    @Published var petViews:[Int:String]=[:]
    @Published var hiddenPets:Set<Int>=[]
    @Published var activityLocked:Set<Int>=[]
    @Published var gameStatus=""
    @Published var focusMinutes=25
    @Published var breakMinutes=5
    @Published var pomodoroRemaining=0
    @Published var pomodoroRunning=false
    @Published var onStudyBreak=false
    @Published var stageKind=""
    @Published var stageLabel=""
    var moodUntil:[Int:Date]=[:]
    var sadnessBegan:[Int:Date]=[:]
    var comfortRequested:[Int:Date]=[:]
    var moodCause:[Int:String]=[:]
    var comfortNeeded:((Int)->Void)?
    var playGame:(()->Void)?
    var stopGame:(()->Void)?
    var studyChanged:(()->Void)?
    var studyCompleted:(()->Void)?
    var dragStudy:((CGSize,Bool)->Void)?
    var pomodoroLast:Date?
    var propTokens:[Int:UUID]=[:]
    let updater=UpdateManager()
    let audio=StudyAudio()
    @Published var houseHint="把小伙伴拖进来，安静住一会儿"
    @Published var bubbleTransparent=UserDefaults.standard.bool(forKey:"bubbleTransparent")
    var startScene:((Scenario)->Void)?
    var stopScene:(()->Void)?
    var showHouse:(()->Void)?
    var showChat:(()->Void)?
    var releasePet:((Int)->Void)?
    var activePets:[Int]{visible.subtracting(housed).sorted()}
    var nextMoodChange:[Int:Date]=[:]
    var lastMoodEvent:[String:Date]=[:]
    var playWithFriend:((Int)->Void)?
    var socialChoice:((Int,Int)->Void)?
    @Published var autoPlay=UserDefaults.standard.object(forKey:"autoPlay") as? Bool ?? true
    var positions:[String:[Double]]=[:]
    var syncWindows:(()->Void)?
    var focusPet:((Int)->Void)?
    var showMain:(()->Void)?
    var dragPet:((Int,CGSize,Bool)->Void)?
    var actionTokens:[Int:UUID]=[:]
    var bubbleTokens:[Int:UUID]=[:]
    var dataURL:URL {
        if Bundle.main.bundleIdentifier?.hasSuffix(".test")==true {return Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("ui-test-data/state.json")}
        if let path=ProcessInfo.processInfo.environment["LITTLECOMPANIONS_DATA_DIR"] {return URL(fileURLWithPath:path).appendingPathComponent("state.json")}
        return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("LittleCompanions/state.json")
    }
    init(){
        if let data=try? Data(contentsOf:dataURL),let saved=try? JSONDecoder().decode(SavedState.self,from:data) {
            visible=Set(saved.visible.filter{(0..<8).contains($0)});chats=saved.chats;schedules=saved.schedules;positions=saved.positions;care=saved.care ?? [:];housed=Set((saved.housed ?? []).filter{(0..<8).contains($0)});bonds=saved.bonds ?? [:];gameSettings=saved.gameSettings ?? GameSettings();playerName=saved.playerName ?? "朋友";focusMinutes=max(1,min(90,saved.focusMinutes ?? 25));breakMinutes=max(1,min(30,saved.breakMinutes ?? 5))
        }
        if let data=try? Data(contentsOf:dataURL),let saved=try? JSONDecoder().decode(SavedState.self,from:data),saved.motionPaddingVersion==nil {for key in Array(positions.keys){if var point=positions[key],point.count==2{point[0]-=MotionLayout.side;positions[key]=point}}}
        normalizeOldOutfits()
    }
    func normalizeOldOutfits(){
        for key in Array(care.keys){
            guard var pet=care[key] else{continue}
            switch pet.outfit{case .scarf:pet.outfit = .bib;case .hoodie:pet.outfit = .whiteSet;case .pajamas:pet.outfit = .pinkSet;default:break}
            care[key]=pet
        }
    }
    func persist(){
        for id in 0..<8 where care["\(id)"]==nil {care["\(id)"]=CareProfile()}
        do {
            try FileManager.default.createDirectory(at:dataURL.deletingLastPathComponent(),withIntermediateDirectories:true)
            let data=try JSONEncoder().encode(SavedState(visible:visible.sorted(),chats:chats,schedules:schedules,positions:positions,care:care,housed:housed.sorted(),bonds:bonds,gameSettings:gameSettings,playerName:playerName,focusMinutes:focusMinutes,breakMinutes:breakMinutes,motionPaddingVersion:1))
            try data.write(to:dataURL,options:.atomic)
        }catch{notice="保存失败：\(error.localizedDescription)"}
    }
    func profile(_ id:Int)->CareProfile {care["\(id)"] ?? CareProfile()}
    func petName(_ id:Int)->String{let name=profile(id).nickname?.trimmingCharacters(in:.whitespacesAndNewlines) ?? "";return name.isEmpty ? Character.all[id].name:name}
    func rename(_ name:String,id:Int){var p=profile(id);p.nickname=String(name.trimmingCharacters(in:.whitespacesAndNewlines).prefix(18));care["\(id)"]=p;persist()}
    func bond(_ a:Int,_ b:Int)->Double{bonds[[a,b].sorted().map(String.init).joined(separator:"-")] ?? Double(30+(min(a,b)*7+max(a,b)*3)%16)}
    func befriend(_ a:Int,_ b:Int,amount:Double=4){guard a != b else{return};let key=[a,b].sorted().map(String.init).joined(separator:"-");bonds[key]=min(100,bond(a,b)+amount)}
    func style(_ id:Int)->String {
        let n=profile(id).nurture ?? [:]
        guard let best=n.max(by:{$0.value<$1.value}),best.value>=3 else{return Character.all[id].persona}
        return best.key=="学习" ? "好奇认真，喜欢把新知识分享给你":best.key=="玩耍" ? "开朗爱探索，喜欢邀请伙伴一起玩":best.key=="照顾" ? "温柔亲近，善于关心和安慰伙伴":"审美活泼，喜欢展示新搭配"
    }
    func expression(_ id:Int)->PetExpression {
        let p=profile(id),action=actions[id] ?? .idle
        if [.eat,.hug].contains(action){return .happy}
        if action == .read || action == .sit{return .neutral}
        if action == .sleep{return .happy}
        if let end=moodUntil[id],end>Date(),let mood=p.mood{return mood}
        // Low energy means resting, never endless crying. Negative expressions expire.
        if p.mood == .sad || p.mood == .angry{return .neutral}
        if p.automaticMood == false{return p.mood ?? .neutral}
        let f=(p.feelings ?? Feelings()).evolved(sleeping:housed.contains(id) || action == .sleep)
        return f.joy>84 && f.energy>35 ? .excited:f.joy>66 ? .happy:.neutral
    }
    func affect(_ event:MoodEvent,id:Int,at now:Date=Date()) {
        let key="\(id)-\(event.reason)"
        if let last=lastMoodEvent[key],now.timeIntervalSince(last)<8{return}
        lastMoodEvent[key]=now
        var p=profile(id);var f=(p.feelings ?? Feelings()).evolved(at:now,sleeping:actions[id] == .sleep);f.receive(event)
        if [.food,.friend,.kindness,.rest].contains(event){f.joy=max(73,f.joy);f.energy=max(38,f.energy)}
        p.feelings=f;p.mood=event == .hurt ? .sad:[.learn,.chat].contains(event) ? .neutral:.happy;p.automaticMood=true
        let key2=event == .learn ? "学习":event == .play ? "玩耍":event == .dress ? "搭配":"照顾"
        p.nurture=p.nurture ?? [:];p.nurture![key2,default:0]+=1;care["\(id)"]=p
        moodUntil[id]=now.addingTimeInterval(event == .hurt ? 7:14);moodCause[id]=event.reason
        if event == .hurt{sadnessBegan[id]=now;comfortRequested[id]=now;comfortNeeded?(id)}else{sadnessBegan.removeValue(forKey:id);if event == .friend{comfortRequested.removeValue(forKey:id)}}
    }
    func updateFeelings(at now:Date=Date()) {
        for id in activePets {
            if let requested=comfortRequested[id]{if now.timeIntervalSince(requested)>30{comfortRequested.removeValue(forKey:id)}else if !busy.contains(id){comfortNeeded?(id)}}
            if let start=sadnessBegan[id],now.timeIntervalSince(start)>=7 {
                var p=profile(id);p.mood = .neutral;var f=p.feelings ?? Feelings();f.joy=max(58,f.joy);f.reason="缓一缓，又能继续陪你啦";p.feelings=f;care["\(id)"]=p;sadnessBegan.removeValue(forKey:id)
            }
            guard now >= (nextMoodChange[id] ?? .distantPast),moodUntil[id,default:.distantPast]<now else{continue}
            var p=profile(id);var f=(p.feelings ?? Feelings()).evolved(at:now,sleeping:actions[id] == .sleep);f.joy=max(55,f.joy);p.feelings=f
            if p.automaticMood != false{p.mood=nil};care["\(id)"]=p
            nextMoodChange[id]=now.addingTimeInterval(25)
        }
    }
    func hold(_ item:String,id:Int,duration:Double?=nil){heldItems[id]=item;let token=UUID();propTokens[id]=token
        if let duration{DispatchQueue.main.asyncAfter(deadline:.now()+duration){[weak self] in guard let self,self.propTokens[id]==token else{return};self.heldItems.removeValue(forKey:id)}}
    }
    func tickPomodoro(at now:Date=Date()){
        guard pomodoroRunning else{return}
        let seconds=max(0,Int(now.timeIntervalSince(pomodoroLast ?? now)));guard seconds>0 else{return};pomodoroLast=(pomodoroLast ?? now).addingTimeInterval(Double(seconds))
        pomodoroRemaining=max(0,pomodoroRemaining-seconds)
        if pomodoroRemaining==0{pomodoroRunning=false;studyCompleted?()}
    }
    func enterHouse(_ id:Int){
        guard !(sceneName==Scenario.study.rawValue && activityLocked.contains(id)) else{notice="请先手动结束学习，再让小伙伴回家。";return}
        var p=profile(id);p.feelings=(p.feelings ?? Feelings()).evolved(sleeping:false);care["\(id)"]=p;housed.insert(id);visible.insert(id);bubbles.removeValue(forKey:id);actions[id] = .idle;actionTokens[id]=UUID();socialMarks.removeValue(forKey:id);comfortRequested.removeValue(forKey:id)
        houseHint="嘘，小伙伴在屋里休息 · 不会自行出来";if activePets.isEmpty{audio.stop();pomodoroRunning=false};syncWindows?();persist()
    }
    func leaveHouse(_ id:Int){var p=profile(id);p.feelings=(p.feelings ?? Feelings()).evolved(sleeping:true);care["\(id)"]=p;housed.remove(id);visible.insert(id);syncWindows?();releasePet?(id);persist()}
    func displayScale(_ id:Int)->Double {petScale*(1+Double(profile(id).stage)*0.05)}
    func favoriteFood(_ id:Int)->String {["暖暖小饭团","胡萝卜小饼干","能量饭团","草莓小点心","坚果小饼干","布朗尼小方块","香香小饭团","水果小拼盘"][id]}
    func feed(_ id:Int,food:Food?=nil){
        let food=food ?? chosenFood
        var pet=profile(id);let now=Date()
        if let last=pet.lastFed,now.timeIntervalSince(last)<1800 {careNotices[id]="刚刚吃过啦，30 分钟后再喂吧。";return}
        let before=pet.stage;pet.lastFed=now;let earned=pet.award(3);care["\(id)"]=pet
        careNotices[id]=earned>0 ? "吃饱啦！成长 +\(earned)":"吃饱啦！今天的成长值已经攒满了，明天再继续。"
        if pet.stage>before{careNotices[id]="长大了一点！进入\(pet.stageName)，解锁新衣服啦。";appearanceChanged?()}
        affect(.food,id:id);if food == Food.favorite(id){var p=profile(id);let joy=p.feelings?.joy ?? 75;p.feelings?.joy=min(95,joy+5);care["\(id)"]=p};say("嚼嚼…\(food.rawValue)好好吃！",id:id);hold(food.emoji,id:id,duration:5);act(.eat,id:id,duration:5);persist()
    }
    func teach(_ text:String,id:Int){
        let lesson=String(text.trimmingCharacters(in:.whitespacesAndNewlines).prefix(300));guard !lesson.isEmpty else{return}
        var pet=profile(id)
        guard !pet.lessons.contains(lesson) else{careNotices[id]="这个我已经记住啦，可以教我一点新东西。";return}
        let before=pet.stage;pet.lessons.append(lesson);pet.lessons=Array(pet.lessons.suffix(20));let earned=pet.award(4)
        care["\(id)"]=pet;careNotices[id]=earned>0 ? "记下来了！成长 +\(earned)":"记下来了！今天的成长值攒满了，学习卡仍会保存。"
        if pet.stage>before{careNotices[id]="进入\(pet.stageName)！可以去衣橱试试新衣服了。";appearanceChanged?()}
        affect(.learn,id:id);say("新的小知识，认真记住啦。",id:id);act(.look,id:id,duration:3);persist()
    }
    func dress(_ outfit:Outfit,id:Int){
        var pet=profile(id);guard pet.canWear(outfit) else{return};pet.outfit=outfit;care["\(id)"]=pet
        affect(.dress,id:id);say(outfit == .none ? "轻轻松松做自己～":"换上\(outfit.rawValue)，给你看看！",id:id);act(.wave,id:id);persist()
    }
    func setMood(_ mood:PetExpression,id:Int){var pet=profile(id);pet.mood=mood;pet.automaticMood=false;care["\(id)"]=pet;moodUntil[id]=Date().addingTimeInterval(mood == .sad || mood == .angry ? 7:30);if mood == .sad{sadnessBegan[id]=Date();comfortNeeded?(id)};persist()}
    func setAccessory(_ accessory:Accessory,id:Int){
        var pet=profile(id);guard pet.xp>=accessory.requiredXP else{return};pet.accessory=accessory;care["\(id)"]=pet;affect(.dress,id:id)
        act(.wave,id:id,duration:2);persist()
    }
    func toggle(_ id:Int){if sceneName==Scenario.study.rawValue && activityLocked.contains(id){notice="请先结束学习再收起小伙伴。";return};if visible.contains(id){visible.remove(id)}else{visible.insert(id)};syncWindows?();persist()}
    func showAll(){visible=Set(0..<8);syncWindows?();persist()}
    func hideAll(){if sceneName==Scenario.study.rawValue{notice="请先结束学习再收起小伙伴。";return};visible=[];syncWindows?();persist()}
    func act(_ action:Action,id:Int,duration:Double?=nil){
        guard !housed.contains(id) else{return}
        if sceneName==Scenario.study.rawValue && activityLocked.contains(id) && ![Action.read,.sit].contains(action){return}
        actions[id]=action; let token=UUID();actionTokens[id]=token
        if action != .sleep && action != .idle && action != .read && action != .sit {
            DispatchQueue.main.asyncAfter(deadline:.now()+(duration ?? (action == .wave ? 2.4:action == .jump ? 2:action == .stretch ? 3.5:action == .look ? 3:5))){[weak self] in guard let self,self.actionTokens[id]==token else{return};self.actions[id] = .idle}
        }
    }
    func say(_ text:String,id:Int,duration:Double=12){
        guard !housed.contains(id) else{return}
        bubbles[id]=String(text.prefix(48));let token=UUID();bubbleTokens[id]=token
        DispatchQueue.main.asyncAfter(deadline:.now()+duration){[weak self] in guard let self,self.bubbleTokens[id]==token else{return};self.bubbles.removeValue(forKey:id)}
    }
    func interact(_ id:Int){selected=id;affect(.touch,id:id);act(.special,id:id);say(Character.all[id].greeting,id:id)}
    func saveSettings(){
        UserDefaults.standard.set(bubbleTransparent,forKey:"bubbleTransparent");UserDefaults.standard.set(socialEnabled,forKey:"socialEnabled");UserDefaults.standard.set(petScale,forKey:"petScaleV2");UserDefaults.standard.set(provider,forKey:"provider");UserDefaults.standard.set(openaiModel,forKey:"openaiModel");UserDefaults.standard.set(deepseekModel,forKey:"deepseekModel");UserDefaults.standard.set(autoPlay,forKey:"autoPlay")
    }
    func send(_ text:String,id:Int){
        let text=String(text.trimmingCharacters(in:.whitespacesAndNewlines).prefix(12000))
        guard !text.isEmpty,!busy.contains(id) else{return}
        let chosenProvider=provider,model=(provider=="OpenAI" ? openaiModel:deepseekModel).trimmingCharacters(in:.whitespacesAndNewlines)
        let env=ProcessInfo.processInfo.environment[provider=="OpenAI" ? "OPENAI_API_KEY":"DEEPSEEK_API_KEY"]
        guard let key=Secrets.read(chosenProvider) ?? env,!key.isEmpty else{errors[id]="请先到「设置」输入已有的 \(chosenProvider) API 密钥并保存。";return}
        guard !model.isEmpty else{errors[id]="请先填写模型名称。";return}
        affect(MoodEvent.conversation(text),id:id);chats["\(id)",default:[]].append(Message(role:"user",text:text));persist()
        busy.insert(id);errors.removeValue(forKey:id);say("认真听你说…",id:id)
        let history=chats["\(id)"] ?? []
        Task {
            defer{busy.remove(id);if comfortRequested[id] != nil{comfortNeeded?(id)}}
            do {
                let reply=try await ChatAPI.request(provider:chosenProvider,model:model,key:key,character:Character.all[id],history:history,knowledge:profile(id).lessons,emotion:expression(id).rawValue+"，"+(profile(id).feelings?.reason ?? "安静陪伴")+"；养成性格："+style(id)+"；用户姓名："+playerName+"；你的昵称："+petName(id)+"；玩家设定的性格："+DesignLibrary.shared.design(id).persona)
                chats["\(id)",default:[]].append(Message(role:"assistant",text:reply));persist();act(.talk,id:id);say(reply,id:id,duration:20)
            }catch{errors[id]=error.localizedDescription;say("暂时没连上，去面板看看原因吧。",id:id)}
        }
    }
    func remind(){
        var changed=false
        for i in schedules.indices where !schedules[i].done && !schedules[i].reminded && schedules[i].date <= Date() {
            schedules[i].reminded=true;changed=true
            guard let id=activePets.first else{notice="日程到啦：\(schedules[i].title)（安静模式）";continue}
            if !visible.contains(id){visible.insert(id);syncWindows?()}
            say("日程到啦：\(schedules[i].title)",id:id,duration:40);act(.wave,id:id);if ProcessInfo.processInfo.environment["LITTLECOMPANIONS_SILENT_TEST"] != "1" {NSSound.beep()}
        }
        if changed{persist()}
    }
}

enum PetExpression:String,Codable,CaseIterable,Identifiable {
    case neutral="豆豆眼",happy="开心",angry="生气",sad="委屈",excited="惊喜"
    var id:String{rawValue}
    var assetKey:String{switch self{case .neutral:return "neutral";case .happy:return "happy";case .angry:return "angry";case .sad:return "sad";case .excited:return "excited"}}
}
enum Accessory:String,Codable,CaseIterable,Identifiable {
    case none="不戴饰品",bow="粉色蝴蝶结",flowers="小花环",visor="蓝色遮阳帽",bucket="黄色野餐帽",glasses="星星眼镜"
    var id:String{rawValue}
    var requiredXP:Int{switch self{case .none:return 0;case .bow:return 12;case .flowers:return 36;case .visor:return 60;case .bucket:return 96;case .glasses:return 120}}
    var assetKey:String{switch self{case .none:return "";case .bow:return "acc-bow";case .flowers:return "acc-flowers";case .visor:return "acc-visor";case .bucket:return "acc-bucket";case .glasses:return "acc-glasses"}}
}
struct PetArt:View {
    let character:Character
    var action:Action = .idle
    var time:Double=0
    var outfit:Outfit = .none
    var expression:PetExpression = .neutral
    var accessory:Accessory = .none
    var held:String? = nil
    var direction:String="front"
    var body:some View {
        CustomPetView(id:character.id,action:action,time:time,expression:expression,outfit:outfit,accessory:accessory,held:held,direction:direction)
            .rotationEffect(.degrees(action == .fly ? -88:action == .dance ? sin(time*7)*7:0))
            .offset(y:action == .jump ? -abs(sin(time*5))*23:action == .fly ? sin(time*3)*5:0)
    }
}

enum MotionLayout {
    static let side:Double=32
    static let top:Double=44
    static func base(_ scale:Double)->NSSize{NSSize(width:max(70,170*scale+20),height:185*scale+25)}
    static func window(_ scale:Double)->NSSize{let size=base(scale);return NSSize(width:size.width+side*2,height:size.height+top)}
    static func hitRegion(_ frame:NSRect)->NSRect{NSRect(x:frame.minX+side,y:frame.minY,width:max(0,frame.width-side*2),height:max(0,frame.height-20))}
}
struct FloatingPet:View {
    @ObservedObject var store:Store
    let id:Int
    @State var hover=false
    var body:some View {
        VStack(spacing:0){
            TimelineView(.animation(minimumInterval:1.0/30)){timeline in
                PetArt(character:Character.all[id],action:store.actions[id] ?? .idle,time:timeline.date.timeIntervalSinceReferenceDate,outfit:store.profile(id).outfit,expression:store.expression(id),accessory:store.profile(id).accessory ?? .none,held:store.heldItems[id],direction:store.petViews[id] ?? "front")
                    .opacity(store.hiddenPets.contains(id) ? 0:1).scaleEffect(x:[Action.walk,.fly].contains(store.actions[id] ?? .idle) ? -(store.facings[id] ?? 1):(store.facings[id] ?? 1),y:1).rotationEffect(.degrees(store.socialLean[id] ?? 0),anchor:.bottom)
            }.frame(width:170*store.displayScale(id),height:185*store.displayScale(id))
            if hover {Text(store.petName(id)).font(.system(size:8,weight:.medium)).padding(.horizontal,5).padding(.vertical,2).background(.ultraThinMaterial,in:Capsule()).allowsHitTesting(false)}
        }
        .frame(width:MotionLayout.base(store.displayScale(id)).width,height:MotionLayout.base(store.displayScale(id)).height,alignment:.top)
        .padding(EdgeInsets(top:MotionLayout.top,leading:MotionLayout.side,bottom:0,trailing:MotionLayout.side))
        .overlay(alignment:.topTrailing){if let mark=store.socialMarks[id]{Text(mark).font(.system(size:12)).foregroundStyle(.pink).padding(.top,MotionLayout.top).padding(.trailing,MotionLayout.side).allowsHitTesting(false)}}
        .overlay(alignment:.topLeading){if let icon=store.sceneIcons[id]{Text(icon).font(.system(size:10)).offset(x:MotionLayout.side+5,y:MotionLayout.top+3).allowsHitTesting(false)}}
        .overlay(NativePetInteraction(store:store,id:id,onHover:{hover=$0}))
    }
}
struct NativePetInteraction:NSViewRepresentable {
    let store:Store
    let id:Int
    let onHover:(Bool)->Void
    func makeNSView(context:Context)->PetInputView {
        let view=PetInputView();view.store=store;view.petID=id;view.hover=onHover;return view
    }
    func updateNSView(_ view:PetInputView,context:Context){view.store=store;view.petID=id;view.hover=onHover}
}
@MainActor final class PetInputView:NSView {
    weak var store:Store?
    var petID=0
    var hover:((Bool)->Void)?
    var start:NSPoint = .zero
    var dragged=false
    var tracking:NSTrackingArea?
    override func hitTest(_ point:NSPoint)->NSView? {
        let local=convert(point,from:superview)
        let active=CGRect(x:MotionLayout.side,y:isFlipped ? 20:0,width:max(0,bounds.width-MotionLayout.side*2),height:max(0,bounds.height-20))
        return active.contains(local) ? super.hitTest(point):nil
    }
    override var acceptsFirstResponder:Bool{true}
    override var mouseDownCanMoveWindow:Bool{false}
    override func acceptsFirstMouse(for event:NSEvent?)->Bool{true}
    override func updateTrackingAreas(){
        super.updateTrackingAreas();if let tracking{removeTrackingArea(tracking)}
        let area=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil);addTrackingArea(area);tracking=area
    }
    override func mouseEntered(with event:NSEvent){hover?(true);if (store?.actions[petID] ?? .idle) == .idle{store?.act(.look,id:petID,duration:2)}}
    override func mouseExited(with event:NSEvent){hover?(false)}
    override func mouseDown(with event:NSEvent){
        start=NSEvent.mouseLocation;dragged=false
        store?.act(.idle,id:petID)
        store?.dragPet?(petID,.zero,false)
    }
    override func mouseDragged(with event:NSEvent){
        let current=NSEvent.mouseLocation
        if hypot(current.x-start.x,current.y-start.y)>2{dragged=true}
        if dragged{store?.dragPet?(petID,CGSize(width:current.x-start.x,height:start.y-current.y),false)}
    }
    override func mouseUp(with event:NSEvent){
        let current=NSEvent.mouseLocation
        store?.dragPet?(petID,dragged ? CGSize(width:current.x-start.x,height:start.y-current.y):.zero,true)
        if !dragged {
            if event.clickCount>=2{store?.selected=petID;store?.showMain?()}else{store?.interact(petID)}
        }
    }
    override func menu(for event:NSEvent)->NSMenu? {
        let menu=NSMenu()
        func add(_ title:String,_ value:String){let item=NSMenuItem(title:title,action:#selector(choose(_:)),keyEquivalent:"");item.target=self;item.representedObject=value;menu.addItem(item)}
        add("和 \(Character.all[petID].name) 聊天","chat")
        add("邀请伙伴抱抱","pair:4");add("一起玩球","pair:6");add("结伴散步","pair:3");add("回小房子休息","home");add("找小伙伴玩","social");
        for scene in Scenario.allCases{add(scene.rawValue,"scene:"+scene.rawValue)}
        add("喂一口","feed");add("打开养成衣橱","care")
        for action in Action.allCases {add(action == .special ? Character.all[petID].special:action.rawValue,action.rawValue)}
        menu.addItem(.separator());add("暂时收起","hide")
        return menu
    }
    @objc func choose(_ item:NSMenuItem){
        guard let value=item.representedObject as? String else{return}
        if value=="chat"{store?.selected=petID;store?.requestedTab=0;store?.showMain?()}
        else if value.hasPrefix("pair:"),let kind=Int(value.dropFirst(5)){store?.socialChoice?(petID,kind)}
        else if value=="home"{store?.showHouse?();store?.enterHouse(petID)}
        else if value.hasPrefix("scene:"),let scene=Scenario(rawValue:String(value.dropFirst(6))){store?.startScene?(scene)}
        else if value=="social"{store?.playWithFriend?(petID)}
        else if value=="feed"{store?.feed(petID)}
        else if value=="care"{store?.selected=petID;store?.requestedTab=2;store?.showMain?()}
        else if value=="hide"{store?.toggle(petID)}
        else if let action=Action(rawValue:value){store?.act(action,id:petID)}
    }
}

struct MainView:View {
    @ObservedObject var store:Store
    @State var tab=0
    @State var draft=""
    @State var lesson=""
    @State var nicknameDraft=""
    @State var eventTitle=""
    @State var eventDate=Date().addingTimeInterval(3600)
    @State var key=""
    @State var keyNote=""
    let purple=Color(red:0.43,green:0.34,blue:0.65)
    var character:Character{Character.all[store.selected]}
    var body:some View {
        HStack(spacing:0){
            VStack(alignment:.leading,spacing:17){
                Text("LittleCompanions\n小小陪伴站").font(.system(size:25,weight:.bold,design:.rounded)).foregroundStyle(purple)
                Text("八个小伙伴 · 一个温暖桌面").font(.caption).foregroundStyle(.secondary)
                HStack{Button("小房子"){store.showHouse?()};Button("迷你聊天"){store.showChat?()}}.controlSize(.small)
                HStack{Button("全部出来"){store.showAll()};Button("全部收起"){store.hideAll()}}.controlSize(.small)
                ScrollView{
                    VStack(spacing:7){ForEach(Character.all){pet in
                        HStack(spacing:7){
                            Button{store.selected=pet.id;key="";keyNote=""}label:{
                                HStack(spacing:8){PetArt(character:pet,outfit:store.profile(pet.id).outfit,expression:store.expression(pet.id),accessory:store.profile(pet.id).accessory ?? .none).frame(width:34,height:38);VStack(alignment:.leading,spacing:3){Text(store.petName(pet.id)).font(.system(size:12,weight:.semibold)).lineLimit(1).minimumScaleFactor(0.8);Text(store.housed.contains(pet.id) ? "屋里休息":pet.animal).font(.caption2).foregroundStyle(.secondary)};Spacer()}
                            }.buttonStyle(.plain)
                            Toggle("显示 \(pet.name)",isOn:Binding(get:{store.visible.contains(pet.id)},set:{_ in store.toggle(pet.id)})).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        }.padding(6).background(store.selected==pet.id ? purple.opacity(0.12):Color.white.opacity(0.5),in:RoundedRectangle(cornerRadius:12))
                    }}}
                Text("桌面拖动 · 右键选择动作\n屋外：\(store.activePets.count) · 屋里：\(store.housed.count)").font(.caption).foregroundStyle(.secondary)
            }.padding(22).frame(width:243).background(Color(red:0.94,green:0.92,blue:0.97))
            VStack(alignment:.leading,spacing:18){
                HStack{
                    VStack(alignment:.leading,spacing:5){Text(store.petName(store.selected)).font(.system(size:29,weight:.bold,design:.rounded));Text("\(character.animal) · \(character.special)").foregroundStyle(.secondary)}
                    Spacer()
                    Menu{ForEach(Action.allCases,id:\.self){a in Button(a == .special ? character.special:a.rawValue){store.act(a,id:store.selected)}}}label:{Label("互动",systemImage:"sparkles")}
                    Button("来到我身边"){if !store.visible.contains(store.selected){store.toggle(store.selected)};store.focusPet?(store.selected);store.interact(store.selected)}
                }
                Picker("面板",selection:$tab){Text("陪我聊天").tag(0);Text("我的日程").tag(1);Text("养成衣橱").tag(2);Text("创造角色").tag(6);Text("角色档案").tag(3);Text("设置").tag(4);Text("一起玩").tag(5)}.pickerStyle(.segmented)
                if tab==6 {CreatorPanel(store:store)} else if tab==0 {chatPanel} else if tab==1 {schedulePanel} else if tab==2 {carePanel} else if tab==3 {profilePanel} else if tab==5 {scenePanel} else {settingsPanel}
                if !store.notice.isEmpty {Text(store.notice).font(.caption).foregroundStyle(.red)}
            }.padding(28).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).background(Color(red:0.99,green:0.98,blue:0.96))
        }.frame(minWidth:900,minHeight:660).tint(purple).onReceive(store.$requestedTab){tab=$0}
    }
    var scenePanel:some View {
        ScrollView{VStack(alignment:.leading,spacing:14){
            Text("今天一起做什么？").font(.title2.bold())
            Text("显示并醒着的小伙伴会参加。屋里的小伙伴继续休息；你可以随时结束情景。").font(.caption).foregroundStyle(.secondary)
            ActivityControls(store:store,audio:store.audio)
            ForEach(Scenario.allCases){scene in
                Button{store.startScene?(scene)}label:{HStack{Text(scene.icon).font(.title);VStack(alignment:.leading){Text(scene.rawValue).font(.headline);Text(scene.lines[0]).font(.caption).foregroundStyle(.secondary)};Spacer();Image(systemName:"play.fill")}.padding(12).background(.white,in:RoundedRectangle(cornerRadius:12))}.buttonStyle(.plain)
            }
            if !store.sceneName.isEmpty{Text(store.sceneName+" · "+store.sceneStep).font(.callout);Button("结束情景"){store.stopScene?()}}
            HStack{Button("找伙伴抱抱"){store.socialChoice?(store.selected,4)};Button("打开小房子"){store.showHouse?()}}
        }}
    }
    var chatPanel:some View {
        VStack(alignment:.leading,spacing:12){
            HStack{Text("与你的 \(character.name) 聊一会儿").font(.caption).foregroundStyle(.secondary);Spacer();Text(store.provider).font(.caption).foregroundStyle(purple)}
            ScrollViewReader{proxy in
                ScrollView{
                    VStack(alignment:.leading,spacing:14){
                        if (store.chats["\(store.selected)"] ?? []).isEmpty {
                            VStack(spacing:12){PetArt(character:character,action:.wave,outfit:store.profile(store.selected).outfit,expression:store.expression(store.selected),accessory:store.profile(store.selected).accessory ?? .none).frame(width:150,height:166);Text(character.greeting).font(.system(size:17,weight:.medium));Text("从今天的小事开始聊吧。").font(.caption).foregroundStyle(.secondary)}.frame(maxWidth:.infinity).padding(.top,25)
                        }
                        ForEach(store.chats["\(store.selected)"] ?? []){msg in
                            HStack{if msg.role=="user"{Spacer(minLength:45)};Text(msg.text).font(.system(size:14)).textSelection(.enabled).padding(14).background(msg.role=="user" ? purple.opacity(0.13):Color.white,in:RoundedRectangle(cornerRadius:16));if msg.role != "user"{Spacer(minLength:45)}}.id(msg.id)
                        }
                        if store.busy.contains(store.selected){HStack{ProgressView().controlSize(.small);Text("认真想一想…").font(.caption)}}
                        Color.clear.frame(height:1).id("bottom")
                    }.padding(5)
                }.onChange(of:store.chats["\(store.selected)"]?.count){_,_ in proxy.scrollTo("bottom",anchor:.bottom)}
            }
            if let error=store.errors[store.selected]{Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)}
            HStack(alignment:.bottom){
                TextField("想说些什么？",text:$draft,axis:.vertical).lineLimit(1...4).textFieldStyle(.plain).padding(13).background(.white,in:RoundedRectangle(cornerRadius:13)).onSubmit{send()}
                Button(action:send){Image(systemName:"arrow.up").font(.headline).frame(width:25,height:28)}.buttonStyle(.borderedProminent).disabled(draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || store.busy.contains(store.selected))
            }
            Text("各角色独立保存对话。发送时，最近 24 条对话和最近 5 张学习卡会交给当前 AI 服务。").font(.system(size:10)).foregroundStyle(.secondary)
        }
    }
    func send(){let text=draft;store.send(text,id:store.selected);if store.errors[store.selected]==nil{draft=""}}
    var schedulePanel:some View {
        VStack(alignment:.leading,spacing:15){
            Text("留一点时间，给重要的小事。").font(.headline)
            Text("本机日程 · 应用运行时用桌宠气泡和提示音提醒。电脑唤醒后会补提醒；暂未同步系统日历。").font(.caption).foregroundStyle(.secondary)
            TextField("日程名称",text:$eventTitle).textFieldStyle(.roundedBorder)
            HStack{DatePicker("时间",selection:$eventDate,displayedComponents:[.date,.hourAndMinute]);Button("添加日程"){
                store.schedules.append(Schedule(title:String(eventTitle.trimmingCharacters(in:.whitespacesAndNewlines).prefix(200)),date:eventDate));eventTitle="";store.persist()
            }.disabled(eventTitle.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}
            Divider()
            ScrollView{VStack(spacing:10){
                if store.schedules.isEmpty {Text("还没有安排，空白也可以很美好。").foregroundStyle(.secondary).padding(35)}
                ForEach(store.schedules.sorted{$0.date<$1.date}){item in
                    HStack{
                        Button{if let i=store.schedules.firstIndex(where:{$0.id==item.id}){store.schedules[i].done.toggle();store.persist()}}label:{Image(systemName:item.done ? "checkmark.circle.fill":"circle")}.buttonStyle(.plain)
                        VStack(alignment:.leading){Text(item.title).strikethrough(item.done);Text(item.date.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary)}
                        Spacer();if item.reminded && !item.done{Text("已提醒").font(.caption).foregroundStyle(.secondary)}
                        Button{store.schedules.removeAll{$0.id==item.id};store.persist()}label:{Image(systemName:"trash")}.buttonStyle(.plain)
                    }.padding(13).background(.white,in:RoundedRectangle(cornerRadius:12))
                }
            }}
        }
    }
    var carePanel:some View {
        let pet=store.profile(store.selected)
        return ScrollView{
            VStack(alignment:.leading,spacing:18){
                HStack(spacing:22){
                    PetArt(character:character,time:1.7,outfit:pet.outfit,expression:store.expression(store.selected),accessory:pet.accessory ?? .none).frame(width:115,height:128)
                    VStack(alignment:.leading,spacing:8){
                        Text("\(store.petName(store.selected)) · \(pet.stageName)").font(.title3.bold())
                        Text("陪伴第 \(max(1,(Calendar.current.dateComponents([.day],from:pet.adopted,to:Date()).day ?? 0)+1)) 天").font(.caption).foregroundStyle(.secondary)
                        ProgressView(value:pet.growth).frame(width:230)
                        Text(pet.stage==3 ? "已经长大啦，继续收藏一起学到的小知识吧。":"成长 \(pet.xp) / \(pet.nextXP) · 继续成长解锁新衣服和饰品").font(.caption)
                        Text("每天最多成长 12 点，慢慢养就好。").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                HStack{TextField("给小伙伴取个昵称",text:$nicknameDraft).textFieldStyle(.roundedBorder);Button("改名"){store.rename(nicknameDraft,id:store.selected);nicknameDraft=""}}
                Text("现在叫：\(store.petName(store.selected)) · 养成性格：\(store.style(store.selected))").font(.caption).foregroundStyle(.secondary)
                HStack{
                    VStack(alignment:.leading,spacing:5){Picker("选一份食物",selection:$store.chosenFood){ForEach(Food.allCases){food in Text(food.emoji+" "+food.rawValue+(food == Food.favorite(store.selected) ? " · 最爱":"")).tag(food)}}.frame(width:220);Text("饱腹度 \(pet.fullness())% · 每次喂食 +3 成长，间隔 30 分钟").font(.caption).foregroundStyle(.secondary)}
                    Spacer();Button("喂一口"){store.feed(store.selected)}.buttonStyle(.borderedProminent)
                }.padding(12).background(.white,in:RoundedRectangle(cornerRadius:13))
                if let notice=store.careNotices[store.selected]{Text(notice).font(.caption).foregroundStyle(purple)}
                VStack(alignment:.leading,spacing:8){
                    Text("教它一点新知识").font(.headline)
                    TextField("例如：我喜欢在晚上画画。也可以教它一个新词。",text:$lesson,axis:.vertical).lineLimit(2...3).textFieldStyle(.roundedBorder)
                    HStack{
                        Text("每张新学习卡 +4 成长。聊天时会参考最近 5 张卡。").font(.caption2).foregroundStyle(.secondary)
                        Spacer();Button("教给它"){store.teach(lesson,id:store.selected);lesson=""}.disabled(lesson.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    }
                    if !pet.lessons.isEmpty {
                        ForEach(Array(pet.lessons.suffix(5).enumerated()),id:\.offset){_,text in Text("· \(text)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)}
                    }
                }
                Toggle("让它自己决定表情",isOn:Binding(get:{pet.automaticMood != false},set:{value in var p=store.profile(store.selected);p.automaticMood=value;if value{p.mood=nil};store.care["\(store.selected)"]=p;store.persist()}))
                Text("现在：\(store.expression(store.selected).rawValue) · \(pet.feelings?.reason ?? "安安静静陪着你")").font(.caption).foregroundStyle(.secondary)
                HStack{Text("临时选择表情").font(.headline);Spacer();Picker("表情",selection:Binding(get:{pet.mood ?? .neutral},set:{store.setMood($0,id:store.selected)})){ForEach(PetExpression.allCases){mood in Text(mood.rawValue).tag(mood)}}.frame(width:180)}
                Divider()
                Text("小衣橱").font(.headline)
                Text("初始不穿衣服。成长后慢慢解锁，也可以一直保持原本的样子。").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal,showsIndicators:false){HStack(spacing:9){ForEach(Outfit.allCases){outfit in
                    Button{store.dress(outfit,id:store.selected)}label:{
                        VStack(spacing:5){
                            PetArt(character:character,time:1.7,outfit:outfit).frame(width:58,height:65)
                            Text(outfit.rawValue).font(.system(size:10,weight:.medium))
                            Text(pet.canWear(outfit) ? (pet.outfit==outfit ? "穿着中":"已解锁"):"\(outfit.requiredXP) 成长解锁").font(.system(size:9)).foregroundStyle(.secondary)
                        }.frame(width:103,height:112).background(pet.outfit==outfit ? purple.opacity(0.13):Color.white,in:RoundedRectangle(cornerRadius:12))
                    }.buttonStyle(.plain).disabled(!pet.canWear(outfit)).opacity(pet.canWear(outfit) ? 1:0.8)
                }}}
                Text("小饰品").font(.headline)
                ScrollView(.horizontal,showsIndicators:false){HStack(spacing:9){ForEach(Accessory.allCases){item in
                    Button{store.setAccessory(item,id:store.selected)}label:{
                        VStack(spacing:5){
                            PetArt(character:character,time:1.7,outfit:pet.outfit,accessory:item).frame(width:58,height:65)
                            Text(item.rawValue).font(.system(size:10,weight:.medium))
                            Text(pet.xp>=item.requiredXP ? ((pet.accessory ?? .none)==item ? "戴着呢":"已解锁"):"\(item.requiredXP) 成长解锁").font(.system(size:9)).foregroundStyle(.secondary)
                        }.frame(width:103,height:112).background((pet.accessory ?? .none)==item ? purple.opacity(0.13):Color.white,in:RoundedRectangle(cornerRadius:12))
                    }.buttonStyle(.plain).disabled(pet.xp<item.requiredXP)
                }}}
            }.padding(.bottom,10)
        }
    }

    var profilePanel:some View {
        ScrollView{VStack(alignment:.leading,spacing:18){
            HStack{PetArt(character:character,action:.special,outfit:store.profile(store.selected).outfit,expression:store.expression(store.selected),accessory:store.profile(store.selected).accessory ?? .none).frame(width:160,height:180);VStack(alignment:.leading,spacing:10){Text(store.petName(store.selected)).font(.title2.bold());Text("由玩家创造");Text(character.feature).font(.callout);Text("招牌互动：\(character.special)").foregroundStyle(purple);Text("伙伴亲密度").font(.headline);ForEach((0..<8).filter{$0 != store.selected},id:\.self){id in Text("\(store.petName(id)) · \(Int(store.bond(store.selected,id))) / 100").font(.caption)}}}
            Text("这只桌宠怎样陪你").font(.headline)
            Text(character.persona).lineSpacing(5)
            HStack{ForEach([Action.wave,.jump,.fly,.sleep],id:\.self){a in Button(a.rawValue){store.act(a,id:store.selected)}}}
        }}
    }
    var settingsPanel:some View {
        ScrollView{VStack(alignment:.leading,spacing:18){
            UpdateControls(updater:store.updater)
            Divider()
            Text("聊天服务").font(.headline)
            Picker("服务",selection:$store.provider){Text("ChatGPT · OpenAI API").tag("OpenAI");Text("DeepSeek API").tag("DeepSeek")}.onChange(of:store.provider){_,_ in key="";keyNote="";store.saveSettings()}
            if store.provider=="OpenAI"{TextField("模型",text:$store.openaiModel).textFieldStyle(.roundedBorder)}else{TextField("模型",text:$store.deepseekModel).textFieldStyle(.roundedBorder)}
            Text("模型名称可以修改为你的账号支持的模型。ChatGPT 订阅和 API 用量分别计费。").font(.caption).foregroundStyle(.secondary)
            SecureField("在这里粘贴已有的 \(store.provider) API 密钥",text:$key).textFieldStyle(.roundedBorder)
            HStack{
                Button("保存到本机钥匙串"){
                    do{try Secrets.save(key.trimmingCharacters(in:.whitespacesAndNewlines),account:store.provider);key="";keyNote="已保存到 macOS 钥匙串（尚未验证服务连接）。";store.saveSettings()}catch{keyNote=error.localizedDescription}
                }.disabled(key.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                Text(Secrets.read(store.provider)==nil ? "未配置密钥":"已配置密钥").font(.caption).foregroundStyle(.secondary)
            }
            Text(keyNote).font(.caption).foregroundStyle(purple)
            Text("密钥由本机钥匙串保管，只发给对应服务的官方 API 地址。对话、学习卡和日程保存在本机；聊天时会发送最近 5 张学习卡，日程不会自动发给 AI。首次保存时，系统可能询问钥匙串权限。").font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack{Text("玩家姓名");TextField("朋友",text:$store.playerName).textFieldStyle(.roundedBorder).frame(width:180).onSubmit{store.playerName=String(store.playerName.prefix(24));store.persist()};Button("保存姓名"){store.playerName=String(store.playerName.prefix(24));store.persist()}}
            HStack{Text("桌宠大小");Slider(value:$store.petScale,in:0.22...0.8).frame(width:180);Text("\(Int(store.petScale*100))%").monospacedDigit();Button("小小一只"){store.petScale=sqrt(0.1);store.saveSettings()}}.onChange(of:store.petScale){_,_ in store.saveSettings()}
            Text("默认宽高约为初版的 32%，占用面积约为初版的 1/10。").font(.caption).foregroundStyle(.secondary)
            Toggle("桌面气泡使用透明背景",isOn:$store.bubbleTransparent).onChange(of:store.bubbleTransparent){_,_ in store.saveSettings();store.bubbleChanged?(store.bubbles)}
            Toggle("小伙伴之间会主动互动",isOn:$store.socialEnabled).onChange(of:store.socialEnabled){_,_ in store.saveSettings()}
            Toggle("小伙伴偶尔自行做动作",isOn:$store.autoPlay).onChange(of:store.autoPlay){_,_ in store.saveSettings()}
            Button("保存设置"){store.saveSettings();keyNote="设置已保存。"}
            Spacer()
        }.onChange(of:store.openaiModel){_,_ in store.saveSettings()}.onChange(of:store.deepseekModel){_,_ in store.saveSettings()}}
    }
}

func currentPetCenter(_ panel:NSPanel)->NSPoint{NSPoint(x:panel.frame.midX,y:panel.frame.midY-MotionLayout.top/2)}
struct CompactChat:View {
    @ObservedObject var store:Store
    @State var draft=""
    var body:some View {
        VStack(spacing:8){
            HStack{Picker("伙伴",selection:$store.selected){ForEach(Character.all){Text(store.petName($0.id)).tag($0.id)}}.labelsHidden();Text(store.expression(store.selected).rawValue).font(.caption).foregroundStyle(.secondary);Button{store.showMain?()}label:{Image(systemName:"slider.horizontal.3")}.help("打开完整管理面板")}
            ScrollViewReader{proxy in ScrollView{LazyVStack(alignment:.leading,spacing:7){
                if (store.chats["\(store.selected)"] ?? []).isEmpty{Text(Character.all[store.selected].greeting).font(.callout).foregroundStyle(.secondary).padding(.vertical,8)}
                ForEach(store.chats["\(store.selected)"] ?? []){msg in HStack{if msg.role=="user"{Spacer(minLength:20)};Text(msg.text).font(.system(size:12)).textSelection(.enabled).padding(8).background(msg.role=="user" ? Color.purple.opacity(0.10):Color.white.opacity(0.55),in:RoundedRectangle(cornerRadius:10));if msg.role != "user"{Spacer(minLength:20)}}}
                if store.busy.contains(store.selected){ProgressView().controlSize(.small)}
                Color.clear.frame(height:1).id("end")
            }}.onChange(of:store.chats["\(store.selected)"]?.count){_,_ in proxy.scrollTo("end",anchor:.bottom)}}
            if let error=store.errors[store.selected]{Text(error).font(.caption2).foregroundStyle(.red).lineLimit(3)}
            HStack{TextField("和我聊聊…",text:$draft).textFieldStyle(.roundedBorder).onSubmit{send()};Button{send()}label:{Image(systemName:"arrow.up.circle.fill")}.disabled(store.busy.contains(store.selected) || draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}
        }.padding(12).background(.ultraThinMaterial).frame(minWidth:280,maxWidth:.infinity,minHeight:220,maxHeight:.infinity)
    }
    func send(){store.send(draft,id:store.selected);if store.errors[store.selected]==nil{draft=""}}
}
struct HouseRoof:Shape {
    func path(in rect:CGRect)->Path{var p=Path();p.move(to:CGPoint(x:2,y:rect.maxY));p.addLine(to:CGPoint(x:rect.midX,y:2));p.addLine(to:CGPoint(x:rect.maxX-2,y:rect.maxY));p.closeSubpath();return p}
}
struct PetHouseView:View {
    @ObservedObject var store:Store
    var body:some View {
        VStack(spacing:3){
            HouseRoof().fill(Color(red:0.79,green:0.57,blue:0.58)).frame(height:24).overlay(alignment:.bottom){Text("LittleCompanions").font(.system(size:11,weight:.heavy,design:.rounded)).foregroundStyle(.white).padding(.bottom,2)}
            HStack{Text("8 间小卧室").font(.system(size:9));Spacer();Menu{Button("全员回家"){for id in store.visible{store.enterHouse(id)}};Button("全部出来玩"){for id in store.housed{store.leaveHouse(id)}}}label:{Image(systemName:"ellipsis.circle")}.menuStyle(.borderlessButton).frame(width:20)}
            LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:3),count:4),spacing:3){ForEach(0..<8,id:\.self){id in
                Button{if store.housed.contains(id){store.leaveHouse(id)}else{store.enterHouse(id)}}label:{
                    ZStack{RoomDecor(id:id);if store.housed.contains(id){PetArt(character:Character.all[id],action:.sleep,time:1.7,outfit:store.profile(id).outfit,accessory:store.profile(id).accessory ?? .none).frame(width:31,height:34)}}.frame(height:39)
                }.buttonStyle(.plain).help(store.petName(id)+(store.housed.contains(id) ? " · 点我出来玩":" · 点我回房间"))
            }}
            Text("\(store.housed.count)/8 在家 · 点击房间放出").font(.system(size:8)).foregroundStyle(.secondary)
        }.padding(8).background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:13)).frame(width:184,height:164)
    }
}

final class PetPanel:NSPanel {
    override var canBecomeKey:Bool{true}
    override var canBecomeMain:Bool{false}
}
@MainActor final class AppDelegate:NSObject,NSApplicationDelegate {
    let store=Store()
    var window:NSWindow!
    var chatWindow:NSWindow?
    var houseWindow:NSPanel?
    var scene:SceneSession?
    var game:GameSession?
    var stageWindow:NSPanel?
    var sceneTokens:[Int:UUID]=[:]
    var pets:[Int:PetPanel]=[:]
    var bubblePanels:[Int:NSPanel]=[:]
    var nextDecision:[Int:Date]=[:]
    var layoutBoundsOverride:NSRect?
    var social:SocialSession?
    var nextSocial=Date().addingTimeInterval(8)
    var socialTargets:[Int:NSPoint]=[:]
    var socialTokens:[Int:UUID]=[:]
    var pairCooldown:[String:Date]=[:]
    var velocities:[Int:CGVector]=[:]
    var targets:[Int:CGPoint]=[:]
    var lastActions:[Int:Action]=[:]
    var timer:Timer?
    var status:NSStatusItem!
    var tick=0
    var directions:[Int:Double]=[:]
    var dragOrigins:[Int:NSPoint]=[:]
    let ballVisual=BallVisualState()
    var ballHomes:[Int:NSPoint]=[:]
    var ballChasing:Set<Int>=[]
    var ballWindow:NSPanel?
    var studyStageOrigin:NSRect?
    var studyPetOrigins:[Int:NSRect]=[:]
    func applicationDidFinishLaunching(_ notification:Notification){
        NSApp.setActivationPolicy(.regular)
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:960,height:720),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="小小造物站";window.isReleasedWhenClosed=false
        window.contentView=NSHostingView(rootView:MainView(store:store));window.center()
        store.releasePet={[weak self] id in
            guard let self,let panel=self.pets[id],let home=self.houseWindow else{return}
            panel.setFrameOrigin(self.clamp(NSPoint(x:home.frame.minX-panel.frame.width-12,y:home.frame.minY),panel:panel));self.savePositions()
        }
        store.playGame={[weak self] in self?.startGame()}
        store.stopGame={[weak self] in self?.endGame()}
        store.studyChanged={[weak self] in self?.applyStudyState()}
        store.studyCompleted={[weak self] in self?.finishStudy()}
        store.dragStudy={[weak self] delta,ended in self?.moveStudy(delta,ended:ended)}
        store.comfortNeeded={[weak self] id in self?.comfort(id)}
        store.startScene={[weak self] kind in self?.beginScene(kind)}
        store.stopScene={[weak self] in self?.endScene(manual:true)}
        store.showHouse={[weak self] in self?.openHouse()}
        store.showChat={[weak self] in self?.openChat()}
        store.socialChoice={[weak self] id,kind in self?.endGame();self?.endScene();self?.startSocial(preferred:id,force:true,kind:kind)}
        store.playWithFriend={[weak self] id in self?.endGame();self?.endScene();self?.startSocial(preferred:id,force:true)}
        store.syncWindows={[weak self] in self?.sync()}
        store.bubbleChanged={[weak self] values in self?.updateBubbles(values)}
        store.appearanceChanged={[weak self] in self?.resizePets()}
        store.showMain={[weak self] in self?.show()}
        store.focusPet={[weak self] id in self?.focus(id)}
        store.dragPet={[weak self] id,translation,ended in
            guard let self,let panel=self.pets[id] else{return}
            if self.scene?.kind == .study{self.moveStudy(translation,ended:ended);return}
            let origin=self.dragOrigins[id] ?? panel.frame.origin
            self.dragOrigins[id]=origin
            panel.setFrameOrigin(self.clamp(NSPoint(x:origin.x+translation.width,y:origin.y-translation.height),panel:panel))
            if ended,self.houseAccepts(currentPetCenter(panel)) {
                self.dragOrigins.removeValue(forKey:id);self.store.enterHouse(id);return
            }
            if ended {
                self.dragOrigins.removeValue(forKey:id);self.velocities[id] = .zero;self.targets.removeValue(forKey:id)
                self.savePositions();self.store.persist()
                self.nextDecision[id]=Date().addingTimeInterval(Double.random(in:3...9))
                if hypot(translation.width,translation.height)>8 {self.store.act(.jump,id:id,duration:0.8)}
            }
        }
        status=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        status.button?.image=NSImage(systemSymbolName:"pawprint.fill",accessibilityDescription:"LittleCompanions")
        let menu=NSMenu()
        for (title,selector) in [("打开陪伴站",#selector(show)),("迷你聊天",#selector(openChat)),("小小安静屋",#selector(openHouse)),("全部出来",#selector(all)),("全部收起",#selector(none)),("退出",#selector(quit))]{let item=NSMenuItem(title:title,action:selector,keyEquivalent:"");item.target=self;menu.addItem(item)}
        status.menu=menu
        let mainMenu=NSMenu();let appMenu=NSMenu();let appItem=NSMenuItem();appItem.submenu=appMenu;mainMenu.addItem(appItem)
        appMenu.addItem(withTitle:"退出 LittleCompanions",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let edit=NSMenu(title:"编辑"),editItem=NSMenuItem();editItem.submenu=edit;mainMenu.addItem(editItem)
        for (title,action,key) in [("剪切",#selector(NSText.cut(_:)),"x"),("复制",#selector(NSText.copy(_:)),"c"),("粘贴",#selector(NSText.paste(_:)),"v"),("全选",#selector(NSText.selectAll(_:)),"a")]{edit.addItem(withTitle:title,action:action,keyEquivalent:key)}
        NSApp.mainMenu=mainMenu
        store.updater.canRestart={[weak self] in self?.scene?.kind != .study}
        store.updater.beforeRestart={[weak self] in self?.savePositions();self?.store.persist()}
        sync();openHouse();show();store.updater.check()
        timer=Timer(timeInterval:1.0/30,repeats:true){[weak self] _ in MainActor.assumeIsolated{self?.update()}}
        RunLoop.main.add(timer!,forMode:.common)
        if CommandLine.arguments.contains("--preview-all"){store.showAll()}
        if CommandLine.arguments.contains("--ui-smoke-test") || Bundle.main.object(forInfoDictionaryKey:"UIIntegrationTest") as? Bool == true {
            DispatchQueue.main.asyncAfter(deadline:.now()+1){[weak self] in self?.smokeTest()}
        }
    }
    func smokeTest(){
        guard ProcessInfo.processInfo.environment["LITTLECOMPANIONS_DATA_DIR"] != nil || Bundle.main.bundleIdentifier?.hasSuffix(".test")==true else {fputs("UI test requires isolated data directory\n",stderr);exit(1)}
        func check(_ value:Bool,_ description:String){if !value {fputs("FAIL: \(description)\n",stderr);exit(1)}}
        store.showAll();check(pets.values.filter(\.isVisible).count==8,"eight pets visible")
        store.visible=[0,2,7];sync();check(pets.values.filter(\.isVisible).count==3,"arbitrary subset")
        store.visible=[4];sync();check(pets[4]?.isVisible==true && pets.values.filter(\.isVisible).count==1,"one pet")
        store.hideAll();check(pets.values.filter(\.isVisible).isEmpty,"hide all")
        store.showAll();focus(0)
        let start=pets[0]!.frame.origin
        store.dragPet?(0,CGSize(width:-25,height:-15),true)
        check(abs(pets[0]!.frame.minX-(start.x-25))<1,"drag position")
        store.act(.walk,id:0);let x=pets[0]!.frame.minX;update();check(pets[0]!.frame.minX != x,"walking moves window")
        store.act(.sleep,id:1);check(store.actions[1] == .sleep,"independent action")
        store.schedules=[Schedule(title:"测试提醒",date:Date().addingTimeInterval(-1)),Schedule(title:"未来",date:Date().addingTimeInterval(3600)),Schedule(title:"已完成",date:Date().addingTimeInterval(-1),done:true)]
        store.remind();check(store.schedules[0].reminded && !store.schedules[1].reminded && !store.schedules[2].reminded,"due reminder only")
        check(store.bubbles[0]?.contains("测试提醒")==true,"reminder bubble")
        store.chats=["0":[Message(role:"user",text:"隔离测试")]];store.persist()
        let restored=Store();check(restored.chats["0"]?.first?.text=="隔离测试" && restored.visible.count==8,"disk persistence")
        store.chats=[:];store.schedules=[];store.bubbles=[:];store.actions=[:];store.notice="";store.persist()
        print("UI PASS: 8 / subset / single / none visibility, drag, movement, independent actions, due-only reminders, disk persistence")
        try? "PASS: visibility 8 / 3 / 1 / 0, drag, movement, independent actions, reminder timing and bubble, disk persistence".write(to:Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("UI-test-result.txt"),atomically:true,encoding:.utf8)
        fflush(stdout)
    }
    @objc func show(){window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
    @objc func all(){store.showAll()}
    @objc func none(){store.hideAll()}
    @objc func quit(){savePositions();store.persist();NSApp.terminate(nil)}
    func sync(){
        for id in 0..<8 {
            if store.visible.contains(id) && !store.housed.contains(id){
                if pets[id]==nil {
                    let panel=PetPanel(contentRect:NSRect(origin:.zero,size:petSize(id)),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
                    panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=false;panel.level = .floating
                    panel.isMovableByWindowBackground=false;panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary];panel.hidesOnDeactivate=false;panel.isReleasedWhenClosed=false
                    panel.contentView=NSHostingView(rootView:FloatingPet(store:store,id:id))
                    let screen=NSScreen.main.map{DesktopBounds.petFrame(full:$0.frame,visible:$0.visibleFrame)} ?? NSRect(x:0,y:-18,width:1440,height:918)
                    let columns=max(1,Int(screen.width/105)),column=id%columns,row=id/columns
                    var point=NSPoint(x:screen.minX+Double(column)*103+40,y:screen.minY+Double(row)*110+14)
                    if let saved=store.positions["\(id)"],saved.count==2 {point=NSPoint(x:saved[0],y:saved[1])}
                    panel.setFrameOrigin(clamp(point,panel:panel));pets[id]=panel
                }
                pets[id]?.orderFrontRegardless()
                nextDecision[id]=nextDecision[id] ?? Date().addingTimeInterval(Double.random(in:2...11))
            }else if let panel=pets[id]{store.positions["\(id)"]=[panel.frame.minX,panel.frame.minY];panel.orderOut(nil);bubblePanels[id]?.orderOut(nil)}
        }
    }
    func petSize(_ id:Int)->NSSize {MotionLayout.window(store.displayScale(id))}
    func resizePets(){
        for (id,panel) in pets {
            let center=panel.frame.midX,bottom=panel.frame.minY
            panel.setContentSize(petSize(id));panel.setFrameOrigin(clamp(NSPoint(x:center-panel.frame.width/2,y:bottom),panel:panel))
        }
        if let pair=social,pair.kind==6,pair.phase==1{updateBall(pair,elapsed:Date().timeIntervalSince(pair.started))}
        anchorBubbles()
    }
    func updateBubbles(_ values:[Int:String]){
        for id in 0..<8 {
            guard let text=values[id],store.visible.contains(id),!store.housed.contains(id) else{bubblePanels[id]?.orderOut(nil);continue}
            if bubblePanels[id]==nil {
                let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:136,height:48),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
                panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=false;panel.level = .floating
                panel.ignoresMouseEvents=true;panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary];panel.hidesOnDeactivate=false
                bubblePanels[id]=panel
            }
            bubblePanels[id]?.contentView=NSHostingView(rootView:Text(text).font(.system(size:10,weight:.medium)).foregroundStyle(Color(red:0.25,green:0.2,blue:0.3)).lineLimit(2).multilineTextAlignment(.center).padding(6).frame(width:136,height:48).background(Color.white.opacity(store.bubbleTransparent ? 0:0.78),in:RoundedRectangle(cornerRadius:11)).padding(.bottom,5))
            bubblePanels[id]?.orderFrontRegardless()
        }
        anchorBubbles()
    }
    func anchorBubbles(){
        for (id,bubble) in bubblePanels where bubble.isVisible {
            guard let pet=pets[id] else{continue}
            let origin=NSPoint(x:pet.frame.midX-bubble.frame.width/2,y:pet.frame.maxY-MotionLayout.top+25)
            let screen=NSScreen.screens.first{$0.frame.intersects(pet.frame)}?.visibleFrame ?? layoutBoundsOverride ?? NSRect(x:0,y:0,width:1440,height:900)
            bubble.setFrameOrigin(DesktopBounds.clamp(origin,size:bubble.frame.size,bounds:screen))
        }
    }
    func clamp(_ point:NSPoint,panel:NSPanel)->NSPoint{
        let chosen=NSScreen.screens.first{$0.frame.contains(NSPoint(x:point.x+panel.frame.width/2,y:point.y+panel.frame.height/2))} ?? NSScreen.screens.first{$0.frame.intersects(panel.frame)} ?? NSScreen.main
        let screen=layoutBoundsOverride ?? chosen.map{DesktopBounds.petFrame(full:$0.frame,visible:$0.visibleFrame)} ?? NSRect(x:0,y:-18,width:1440,height:918)
        return DesktopBounds.clamp(point,size:panel.frame.size,bounds:screen.insetBy(dx:-MotionLayout.side,dy:0))
    }
    func focus(_ id:Int){if scene?.kind == .study{return};guard !store.housed.contains(id) else{openHouse();return};guard let panel=pets[id],let screen=NSScreen.main else{return};panel.setFrameOrigin(NSPoint(x:screen.visibleFrame.maxX-230,y:screen.visibleFrame.minY+25));panel.orderFrontRegardless()}
    func update(){
        tick+=1
        if let stage=stageWindow,scene?.kind == .study {
            let handle=NSRect(x:stage.frame.minX,y:stage.frame.maxY-25,width:stage.frame.width,height:25)
            stage.ignoresMouseEvents=studyStageOrigin==nil && !handle.contains(NSEvent.mouseLocation)
        }
        for id in store.activePets {
            guard let panel=pets[id],let screen=NSScreen.screens.first(where:{$0.frame.intersects(panel.frame)}) else{continue}
            if dragOrigins[id]==nil{panel.ignoresMouseEvents = !MotionLayout.hitRegion(panel.frame).contains(NSEvent.mouseLocation)}
            let action=store.actions[id] ?? .idle
            let moving=game==nil && scene?.kind != .study && (action == .walk || action == .fly || (action == .special && id==0))
            if moving && dragOrigins[id]==nil {
                if lastActions[id] != action || targets[id]==nil {
                    let heading=Bool.random() ? 1.0:-1.0
                    targets[id]=socialTargets[id] ?? clamp(NSPoint(x:panel.frame.minX+heading*Double.random(in:45...160),y:panel.frame.minY+(action == .fly ? Double.random(in:-50...85):0)),panel:panel)
                }
                let target=targets[id]!,origin=panel.frame.origin
                let dx=target.x-origin.x,dy=target.y-origin.y,distance=hypot(dx,dy)
                if distance<2 {store.act(.idle,id:id);targets.removeValue(forKey:id);velocities[id] = .zero}
                else {
                    let maxSpeed=action == .fly ? 63.0:32.0
                    let speed=min(maxSpeed,distance*2.0)
                    let desired=CGVector(dx:dx/distance*speed,dy:dy/distance*speed)
                    var v=velocities[id] ?? .zero
                    v.dx+=(desired.dx-v.dx)*0.13;v.dy+=(desired.dy-v.dy)*0.13;velocities[id]=v
                    panel.setFrameOrigin(clamp(NSPoint(x:origin.x+v.dx/30,y:origin.y+v.dy/30),panel:panel))
                    if abs(v.dx)>3 {let facing=v.dx>=0 ? 1.0:-1.0;if store.facings[id] != facing{store.facings[id]=facing}}
                }
            } else {velocities[id] = .zero;targets.removeValue(forKey:id)}
            lastActions[id]=action
            if tick%6==0 && store.autoPlay && !store.busy.contains(id) && dragOrigins[id]==nil && action == .idle && social?.a != id && social?.b != id && scene == nil && game == nil && !store.activityLocked.contains(id) {
                let now=Date()
                if now >= (nextDecision[id] ?? now.addingTimeInterval(1)) {
                    let personal:[[Action]]=[
                        [.walk,.walk,.look,.special,.stretch],
                        [.look,.jump,.special,.walk,.dance],
                        [.stretch,.dance,.special,.jump,.walk],
                        [.special,.dance,.look,.stretch,.walk],
                        [.special,.look,.jump,.dance,.walk],
                        [.special,.fly,.wave,.jump,.look],
                        [.walk,.look,.stretch,.special,.wave],
                        [.wave,.look,.special,.jump,.walk]
                    ]
                    if Int.random(in:0..<4)>0 {
                        let habits=store.profile(id).nurture ?? [:],style=habits.max(by:{$0.value<$1.value})
                        let options:[Action]=style?.value ?? 0 >= 3 ? (style?.key=="学习" ? [.look,.stretch,.back]:style?.key=="玩耍" ? [.jump,.dance,.walk]:[.wave,.look,.special]):personal[id]
                        store.act(options.randomElement()!,id:id,duration:Double.random(in:2...6))
                        if style?.key=="学习"{store.hold("📖",id:id,duration:4)}
                    }
                    nextDecision[id]=now.addingTimeInterval(Double.random(in:5...17))
                }
            }
            _ = screen
        }
        if tick%6==0{updateScene();updateSocial()};if tick%3==0{updateGame()}
        anchorBubbles()
        if tick%30==0{store.remind();store.updateFeelings();store.tickPomodoro()}
        if tick%300==0{savePositions();store.persist()}
    }
    func savePositions(){for (id,panel) in pets{store.positions["\(id)"]=[panel.frame.minX,panel.frame.minY]}}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{false}
    func applicationWillTerminate(_ notification:Notification){savePositions();store.persist()}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool{show();return true}
}

enum BallMotion {
    static func sample(_ elapsed:Double)->(forward:Bool,phase:Double,travel:Double,lift:Double){
        let turn=max(0,elapsed)/1.65,phase=turn-floor(turn)
        let progress=max(0,min(1,(phase-0.22)/0.64))
        // Ease out of the paw, hop twice, slow down at the receiving paw.
        let travel=progress*progress*(3-2*progress)
        return (Int(turn)%2==0,phase,travel,sin(progress*Double.pi)*10+abs(sin(progress*Double.pi*2))*7)
    }
}
@MainActor final class BallVisualState:ObservableObject {@Published var lift:Double=0}
struct SoccerBallHost:View {
    @ObservedObject var state:BallVisualState
    var body:some View{TimelineView(.animation(minimumInterval:1.0/30)){time in SoccerBall(rotation:time.date.timeIntervalSinceReferenceDate*220,lift:state.lift)}}
}
struct SoccerBall:View {
    let rotation:Double
    var lift:Double=0
    var body:some View {
        ZStack{Ellipse().fill(.black.opacity(0.12)).frame(width:17,height:4).position(x:15,y:48)
            ZStack{Circle().fill(.white);Circle().stroke(Color.gray.opacity(0.7),lineWidth:0.8)
                ForEach(0..<5,id:\.self){i in RoundedRectangle(cornerRadius:1).fill(Color(white:0.2)).frame(width:5,height:5).rotationEffect(.degrees(72*Double(i))).offset(x:cos(Double(i)*Double.pi*0.4)*6,y:sin(Double(i)*Double.pi*0.4)*6)}
                Circle().fill(Color(white:0.2)).frame(width:5,height:5)
            }.frame(width:19,height:19).rotationEffect(.degrees(rotation)).position(x:15,y:39-lift)
        }.frame(width:30,height:60)
    }
}
extension AppDelegate {
    func updateBall(_ pair:SocialSession,elapsed:Double){
        guard let a=pets[pair.a],let b=pets[pair.b] else{return}
        if ballHomes.isEmpty{ballHomes=[pair.a:a.frame.origin,pair.b:b.frame.origin]}
        let state=BallMotion.sample(elapsed),receiver=state.forward ? pair.b:pair.a
        ballChasing=[]
        for id in [pair.a,pair.b]{if let home=ballHomes[id],let panel=pets[id]{
            let missed=Int(elapsed/1.65)%3==2 && id==receiver && state.phase>0.25
            let goal=clamp(NSPoint(x:home.x+(missed ? (home.x<(ballHomes[id==pair.a ? pair.b:pair.a]?.x ?? home.x) ? -13:13):0),y:home.y),panel:panel)
            let dx=goal.x-panel.frame.minX
            if abs(dx)>0.5{panel.setFrameOrigin(NSPoint(x:panel.frame.minX+max(-0.8,min(0.8,dx)),y:goal.y));ballChasing.insert(id)}
        }}
        let sample=BallMotion.sample(elapsed),left=a.frame.midX<b.frame.midX
        let sign=left ? 1.0:-1.0
        let ax=a.frame.midX+sign*170*store.displayScale(pair.a)*0.20
        let bx=b.frame.midX-sign*170*store.displayScale(pair.b)*0.20
        let ay=a.frame.minY+25+16*store.displayScale(pair.a)+9
        let by=b.frame.minY+25+16*store.displayScale(pair.b)+9
        let t=sample.forward ? sample.travel:1-sample.travel
        if ballWindow==nil{let w=NSPanel(contentRect:NSRect(x:0,y:0,width:30,height:60),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false);w.isOpaque=false;w.backgroundColor = .clear;w.hasShadow=false;w.level = .floating;w.ignoresMouseEvents=true;w.hidesOnDeactivate=false;w.isReleasedWhenClosed=false;w.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary];w.contentView=NSHostingView(rootView:SoccerBallHost(state:ballVisual));ballWindow=w}
        ballVisual.lift=sample.lift
        ballWindow?.setFrameOrigin(NSPoint(x:ax+(bx-ax)*t-15,y:ay+(by-ay)*t-21));ballWindow?.orderFrontRegardless()
    }
}
struct SocialSession {let a,b:Int;let kind:Int;var phase=0;var started:Date;var replied=false}
enum SocialRules {
    static func canJoin(_ action:Action,busy:Bool,dragging:Bool)->Bool{!busy && !dragging && [.idle,.look,.stretch].contains(action)}
}
extension AppDelegate {
    func startSocial(preferred:Int?=nil,force:Bool=false,kind:Int?=nil,partner:Int?=nil){
        if force && social != nil{endSocial()}
        guard game==nil,scene==nil,social==nil,(store.socialEnabled || force) else{return}
        let eligible=store.activePets.filter{id in SocialRules.canJoin(store.actions[id] ?? .idle,busy:store.busy.contains(id),dragging:dragOrigins[id] != nil)}.sorted()
        guard eligible.count>=2 else{if let id=preferred{store.say("叫一个醒着的小伙伴出来玩吧。",id:id)};return}
        let a=preferred.flatMap{eligible.contains($0) ? $0:nil} ?? eligible.first(where:{store.sadnessBegan[$0] != nil}) ?? eligible.randomElement()!
        guard let pa=pets[a],let bounds=layoutBoundsOverride ?? NSScreen.screens.first(where:{$0.frame.intersects(pa.frame)})?.frame else{return}
        let choices=eligible.filter{id in id != a && pets[id].map{bounds.intersects($0.frame)}==true && (force || Date().timeIntervalSince(pairCooldown[[a,id].sorted().map(String.init).joined(separator:"-")] ?? .distantPast)>35)}
        guard let b=partner.flatMap({choices.contains($0) ? $0:nil}) ?? choices.min(by:{lhs,rhs in
            guard let l=pets[lhs],let r=pets[rhs] else{return false}
            return hypot(l.frame.midX-pa.frame.midX,l.frame.midY-pa.frame.midY)-store.bond(a,lhs)*1.5 < hypot(r.frame.midX-pa.frame.midX,r.frame.midY-pa.frame.midY)-store.bond(a,rhs)*1.5
        }),let pb=pets[b] else{return}
        let now=Date(),mid=NSPoint(x:(pa.frame.midX+pb.frame.midX)/2,y:(pa.frame.minY+pb.frame.minY)/2)
        social=SocialSession(a:a,b:b,kind:kind ?? (store.sadnessBegan[a] != nil || store.sadnessBegan[b] != nil ? 4:Int.random(in:0..<8)),started:now)
        let separation=social!.kind==4 ? max(20,max(1,min(pa.frame.width,pb.frame.width)-MotionLayout.side*2)*0.34):social!.kind==5 ? 40.0:social!.kind==6 ? max(115,170*max(store.displayScale(a),store.displayScale(b))*1.3):65.0
        socialTargets[a]=clamp(NSPoint(x:mid.x-separation/2-pa.frame.width/2,y:mid.y),panel:pa)
        socialTargets[b]=clamp(NSPoint(x:mid.x+separation/2-pb.frame.width/2,y:mid.y),panel:pb)
        for id in [a,b]{store.act(.walk,id:id,duration:35);socialTokens[id]=store.actionTokens[id];nextDecision[id]=now.addingTimeInterval(40)}
        nextSocial=now.addingTimeInterval(Double.random(in:17...29))
    }
    func endSocial(){
        ballWindow?.orderOut(nil);ballHomes=[:];ballChasing=[]
        guard let pair=social else{return}
        pairCooldown[[pair.a,pair.b].sorted().map(String.init).joined(separator:"-")]=Date()
        for id in [pair.a,pair.b] {
            if store.actionTokens[id]==socialTokens[id]{store.act(.idle,id:id)}
            socialTargets.removeValue(forKey:id);targets.removeValue(forKey:id);socialTokens.removeValue(forKey:id);store.socialMarks.removeValue(forKey:id);store.socialLean.removeValue(forKey:id)
            nextDecision[id]=Date().addingTimeInterval(Double.random(in:4...10))
        }
        social=nil
    }
    func updateSocial(){
        guard var pair=social else{
            if store.socialEnabled && Date()>=nextSocial {startSocial();nextSocial=Date().addingTimeInterval(Double.random(in:10...22))}
            return
        }
        let ids=[pair.a,pair.b]
        if ids.contains(where:{!store.visible.contains($0) || store.housed.contains($0) || store.actions[$0] == .sleep || store.busy.contains($0) || dragOrigins[$0] != nil}){endSocial();return}
        guard let pa=pets[pair.a],let pb=pets[pair.b] else{endSocial();return}
        let elapsed=Date().timeIntervalSince(pair.started)
        if pair.phase==0 {
            let threshold=pair.kind==4 ? max(24,max(1,min(pa.frame.width,pb.frame.width)-MotionLayout.side*2)*0.34)+7:pair.kind==5 ? 49.0:pair.kind==6 ? max(130,170*max(store.displayScale(pair.a),store.displayScale(pair.b))*1.3+15):85.0
            if pair.kind==6 ? abs(abs(pa.frame.midX-pb.frame.midX)-max(115,170*max(store.displayScale(pair.a),store.displayScale(pair.b))*1.3))<15 && abs(pa.frame.minY-pb.frame.minY)<10:hypot(pa.frame.midX-pb.frame.midX,pa.frame.midY-pb.frame.midY)<threshold {
                pair.phase=1;pair.started=Date();socialTargets.removeAll();targets.removeValue(forKey:pair.a);targets.removeValue(forKey:pair.b)
                store.facings[pair.a]=pa.frame.midX<pb.frame.midX ? 1:-1;store.facings[pair.b]=pa.frame.midX<pb.frame.midX ? -1:1
                let action:Action=pair.kind==1 ? .jump:pair.kind==2 ? .look:pair.kind==4 ? .hug:pair.kind==6 ? .look:pair.kind==7 ? .dance:.wave
                for id in ids{store.act(action,id:id,duration:4);socialTokens[id]=store.actionTokens[id];store.socialMarks[id]=pair.kind==1 ? "🎉":pair.kind==6 ? "":pair.kind==5 ? "✋":pair.kind==7 ? "🎶":["🌼","🍀","☀️","✨","🫧","⭐️","🌈","🤗"][id]}
                if pair.kind==4{let lean=pa.frame.midX<pb.frame.midX ? 12.0:-12.0;store.socialLean[pair.a]=lean;store.socialLean[pair.b] = -lean}
                store.befriend(pair.a,pair.b,amount:pair.kind==4 ? 7:4);for id in ids{store.affect(pair.kind==4 ? .friend:pair.kind>=4 ? .play:.friend,id:id)}
                let opener=["嗨，\(store.petName(pair.b))！","一起跳一下？","我学会挥手啦，你看！","一起走一小段？","靠近一点，抱抱你～","来击个掌！","小球传给你，接住！","一起跳个小舞吧！"][pair.kind]
                store.say(opener,id:pair.a,duration:5)
            }else if elapsed>32 {endSocial();return}
        }else{
            if pair.kind==6 {
                let sample=BallMotion.sample(elapsed)
                for id in ids {
                    let kicker=sample.forward ? pair.a:pair.b
                    let desired:Action=ballChasing.contains(id) ? .walk:id==kicker && sample.phase<0.28 ? .kick:.look
                    if store.actions[id] != desired{store.act(desired,id:id,duration:20);socialTokens[id]=store.actionTokens[id]}
                }
            }
            if !pair.replied && elapsed>0.9 {
                pair.replied=true
                store.say(["来啦，一起陪着你～","一、二、三！","那我们一起打招呼。","好呀，走啦～","抱住啦，暖乎乎的。","啪！我们真默契。","接到啦！再传回来～","跟上你的节拍～"][pair.kind],id:pair.b,duration:4)
                if pair.kind==3 {
                    let sign=pa.frame.midX+pb.frame.midX<2*(NSScreen.main?.visibleFrame.midX ?? 600) ? 1.0:-1.0
                    for id in ids {if let panel=pets[id]{socialTargets[id]=clamp(NSPoint(x:panel.frame.minX+sign*90,y:panel.frame.minY),panel:panel);targets.removeValue(forKey:id);store.act(.walk,id:id,duration:4);socialTokens[id]=store.actionTokens[id]}}
                }
            }
            if elapsed>(pair.kind==6 ? 10:6) {endSocial();return}
        }
        social=pair
    }
}

extension AppDelegate {
    func houseAccepts(_ point:NSPoint)->Bool {guard let home=houseWindow,home.isVisible else{return false};return home.frame.contains(point)}
    @objc func openChat(){
        if chatWindow==nil {
            let w=NSWindow(contentRect:NSRect(x:0,y:0,width:320,height:300),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
            w.title="和小伙伴聊聊";w.isReleasedWhenClosed=false;w.minSize=NSSize(width:290,height:250)
            w.contentView=NSHostingView(rootView:CompactChat(store:store));w.center();chatWindow=w
        }
        chatWindow?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    @objc func openHouse(){
        if houseWindow==nil {
            let home=NSPanel(contentRect:NSRect(x:0,y:0,width:184,height:164),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            home.isOpaque=false;home.backgroundColor = .clear;home.hasShadow=false;home.level = .floating;home.hidesOnDeactivate=false;home.isReleasedWhenClosed=false
            home.isMovableByWindowBackground=true;home.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
            home.contentView=NSHostingView(rootView:PetHouseView(store:store))
            let screen=NSScreen.main?.visibleFrame ?? NSRect(x:0,y:0,width:1440,height:900)
            home.setFrameOrigin(NSPoint(x:screen.maxX-240,y:screen.minY+5));houseWindow=home
        }
        houseWindow?.orderFrontRegardless()
    }
    func activityMembers()->[Int]{store.activePets.filter{store.actions[$0] != .sleep && !store.busy.contains($0) && dragOrigins[$0]==nil && pets[$0] != nil}}
    func openStage(_ kind:String,members:[Int]){
        guard let first=members.first.flatMap({pets[$0]}) else{return}
        let bounds=layoutBoundsOverride ?? NSScreen.screens.first{$0.frame.intersects(first.frame)}?.visibleFrame ?? NSRect(x:0,y:0,width:1440,height:900)
        let center=members.compactMap{pets[$0]?.frame.midX}.reduce(0,+)/Double(max(1,members.count))
        let bottom=max(bounds.minY,members.compactMap{pets[$0]?.frame.minY}.min() ?? bounds.minY)
        if stageWindow==nil{let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:330,height:148),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false);panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=false;panel.level = .floating;panel.ignoresMouseEvents=true;panel.hidesOnDeactivate=false;panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary];panel.isReleasedWhenClosed=false;panel.contentView=NSHostingView(rootView:StageHost(store:store));stageWindow=panel}
        let position=DesktopBounds.clamp(NSPoint(x:center-165,y:bottom),size:NSSize(width:330,height:148),bounds:bounds)
        stageWindow?.setFrameOrigin(position);store.stageKind=kind;store.stageLabel="";stageWindow?.orderFrontRegardless()
        for id in members{pets[id]?.orderFrontRegardless()}
    }
    func stageSeat(_ point:NSPoint,id:Int){guard let panel=pets[id],let stage=stageWindow else{return};let delta=stage.frame.minX+point.x-panel.frame.midX;if abs(delta)>2{store.facings[id]=delta>0 ? 1:-1};panel.setFrameOrigin(clamp(NSPoint(x:stage.frame.minX+point.x-panel.frame.width/2,y:stage.frame.minY+point.y),panel:panel));targets.removeValue(forKey:id);velocities[id] = .zero}
    func groupSeats(_ members:[Int],circle:Bool=false){
        var remaining=members,grouped:[Int]=[]
        while let first=remaining.first{remaining.removeFirst();grouped.append(first);if let buddy=remaining.max(by:{store.bond(first,$0)<store.bond(first,$1)}){grouped.append(buddy);remaining.removeAll{$0==buddy}}}
        let points=circle ? GameRules.seats(count:members.count,center:NSPoint(x:165,y:32),rx:105,ry:24):members.enumerated().map{i,_ in NSPoint(x:70+Double((i/2)%3)*83+Double(i%2)*22,y:16+Double(i/6)*42+Double(i%2)*14)}
        for (i,id) in grouped.enumerated(){stageSeat(points[i],id:id)}
    }
    func cleanupActivity(_ members:[Int]){
        for id in members{store.activityLocked.remove(id);store.hiddenPets.remove(id);store.heldItems.removeValue(forKey:id);store.petViews.removeValue(forKey:id);store.sceneIcons.removeValue(forKey:id);store.socialMarks.removeValue(forKey:id);store.socialLean.removeValue(forKey:id);socialTargets.removeValue(forKey:id);targets.removeValue(forKey:id);store.act(.idle,id:id);nextDecision[id]=Date().addingTimeInterval(10)}
        stageWindow?.orderOut(nil);store.stageKind="";store.stageLabel=""
    }
    func beginScene(_ kind:Scenario){
        if scene?.kind == .study{store.notice="学习还在继续，结束学习后再切换活动。";return}
        endGame();endScene();endSocial()
        let members=activityMembers();guard !members.isEmpty else{store.notice="先让醒着的小伙伴出来吧，屋里的伙伴不会被叫出来。";return}
        openStage(kind.rawValue,members:members);groupSeats(members,circle:kind == .party || kind == .rest)
        scene=SceneSession(kind:kind,members:members);store.sceneName=kind.rawValue;store.sceneStep="一起准备好啦";store.notice="";store.activityLocked.formUnion(members)
        if kind == .study{
            store.pomodoroRemaining=store.focusMinutes*60;store.pomodoroRunning=true;store.onStudyBreak=false;store.pomodoroLast=Date();store.persist();applyStudyState()
        }
    }
    func moveStudy(_ translation:CGSize,ended:Bool){
        guard let current=scene,current.kind == .study,let stage=stageWindow else{return}
        if studyStageOrigin==nil {studyStageOrigin=stage.frame;studyPetOrigins=Dictionary(uniqueKeysWithValues:current.members.compactMap{id in pets[id].map{(id,$0.frame)}})}
        guard let origin=studyStageOrigin else{return}
        let bounds=layoutBoundsOverride ?? NSScreen.screens.first{$0.frame.intersects(origin)}?.visibleFrame ?? origin.insetBy(dx:-500,dy:-300)
        let union=studyPetOrigins.values.reduce(origin){$0.union($1)}
        let dx=max(bounds.minX-union.minX,min(bounds.maxX-union.maxX,translation.width))
        let dy=max(bounds.minY-union.minY,min(bounds.maxY-union.maxY,-translation.height))
        stage.setFrameOrigin(NSPoint(x:origin.minX+dx,y:origin.minY+dy))
        for (id,frame) in studyPetOrigins{pets[id]?.setFrameOrigin(NSPoint(x:frame.minX+dx,y:frame.minY+dy));targets.removeValue(forKey:id);socialTargets.removeValue(forKey:id);velocities[id] = .zero}
        if ended{studyStageOrigin=nil;studyPetOrigins=[:];savePositions();store.persist()}
    }
    func finishStudy(){
        guard let current=scene,current.kind == .study else{return}
        for id in current.members{var p=store.profile(id);_ = p.award(2);store.care["\(id)"]=p;store.affect(.kindness,id:id)}
        endScene(manual:true);store.notice="本轮学习完成啦，休息一下吧！";store.persist()
    }
    func applyStudyState(){
        guard let current=scene,current.kind == .study else{return}
        for (i,id) in current.members.enumerated(){
            stageSeat(NSPoint(x:48+Double(i%4)*76,y:i<4 ? 14:52),id:id)
            store.act(store.onStudyBreak ? .sit:.read,id:id);store.heldItems[id]=store.onStudyBreak ? nil:"📖"
            store.sceneIcons[id]=store.onStudyBreak ? "☕️":"✏️";store.affect(store.onStudyBreak ? .rest:.learn,id:id)
        }
        store.sceneStep=store.onStudyBreak ? "休息一下，安静坐着喝口水":"各自拿好书，安静自习中"
        store.stageLabel=store.sceneStep
    }
    func endScene(manual:Bool=false){
        guard let current=scene else{return}
        if current.kind == .study && !manual{return}
        studyStageOrigin=nil;studyPetOrigins=[:]
        cleanupActivity(current.members);scene=nil;sceneTokens=[:];store.sceneName="";store.sceneStep="";store.pomodoroRunning=false;store.pomodoroRemaining=0;store.audio.stop();nextSocial=Date().addingTimeInterval(15)
    }
    func updateScene(){
        guard var current=scene else{return}
        if current.kind == .study{
            for id in current.members{if store.actions[id] != .read{store.act(.read,id:id)};store.heldItems[id]="📖"}
            return
        }
        if current.members.contains(where:{store.housed.contains($0) || !store.visible.contains($0) || store.busy.contains($0) || dragOrigins[$0] != nil}){endScene();return}
        if !current.performed{
            current.performed=true;current.started=Date();let index=current.phase
            store.sceneStep=current.kind.lines[index];store.stageLabel=store.sceneStep
            for (i,id) in current.members.enumerated(){
                let action:Action
                switch current.kind{case .outing:action=[.look,.walk,.wave,.stretch][index];case .picnic:action=[.sit,.eat,.jump,.hug][index];case .party:action=index==2 ? .jump:.dance;case .rest:action=index==2 ? .sleep:.sit;case .study:action = .read}
                store.act(action,id:id,duration:9)
                store.heldItems[id]=current.kind == .picnic && index==1 ? Food.allCases[i%Food.allCases.count].emoji:current.kind == .party ? (i==index%current.members.count ? "🎤":nil):nil
                store.sceneIcons[id]=["✨","🍀","🎉","🌼","☀️","🎶","🫧","⭐️"][(i+index)%8]
                if current.kind == .outing && index==1,let panel=pets[id]{socialTargets[id]=clamp(NSPoint(x:panel.frame.minX+22,y:panel.frame.minY+Double(i%2)*4),panel:panel)}
                store.affect(current.kind == .rest ? .rest:current.kind == .picnic && index==1 ? .food:.play,id:id)
                if i>0{store.befriend(current.members[i-1],id,amount:2)}
            }
            if current.kind == .picnic && index==3{for i in stride(from:0,to:current.members.count-1,by:2){let a=current.members[i],b=current.members[i+1];let x=70+Double(i/2)*82;stageSeat(NSPoint(x:x,y:24),id:a);stageSeat(NSPoint(x:x+25,y:24),id:b);store.socialLean[a]=10;store.socialLean[b] = -10;store.affect(.friend,id:a);store.affect(.friend,id:b)}}
            if let speaker=current.members.randomElement(){store.say(current.kind.lines[index],id:speaker,duration:5)}
        }else if Date().timeIntervalSince(current.started)>8{
            current.phase+=1;current.performed=false
            if current.phase>=4{endScene();store.persist();return}
        }
        scene=current
    }
    func startGame(){
        if scene?.kind == .study{store.notice="先结束学习，再一起玩游戏吧。";return}
        endGame();endScene();endSocial()
        let settings=store.gameSettings,members=activityMembers()
        guard members.count>=settings.kind.minimum else{store.notice="\(settings.kind.rawValue)需要至少 \(settings.kind.minimum) 只屋外醒着的小伙伴。";return}
        openStage(settings.kind.rawValue,members:members);groupSeats(members,circle:true);store.activityLocked.formUnion(members)
        game=GameSession(settings:settings,members:members);store.gameStatus="准备开始";store.notice=""
    }
    func endGame(){guard let current=game else{return};cleanupActivity(current.members);game=nil;store.gameStatus="游戏结束，下次再一起玩！";store.persist();nextSocial=Date().addingTimeInterval(15)}
    func gamePose(_ action:Action,id:Int){if store.actions[id] != action{store.act(action,id:id,duration:3)}}
    func updateGame(at now:Date=Date()){
        guard var g=game else{return}
        if g.members.contains(where:{store.housed.contains($0) || !store.visible.contains($0) || store.busy.contains($0) || dragOrigins[$0] != nil}){endGame();return}
        let elapsed=max(0,now.timeIntervalSince(g.started)),duration=Double(max(8,g.settings.seconds)),progress=min(1,elapsed/duration)
        let lead=g.members[g.round%g.members.count]
        let title=g.settings.title.isEmpty ? g.settings.kind.rawValue:g.settings.title
        store.gameStatus="\(title) · 第 \(g.round+1)/\(g.settings.rounds) 轮";store.stageLabel=store.gameStatus+(g.settings.customRules.isEmpty ? "":" · "+String(g.settings.customRules.prefix(32)))
        if !g.announced{
            g.announced=true;g.revealed=[];g.hands=[:];store.heldItems=store.heldItems.filter{!g.members.contains($0.key)};store.hiddenPets.subtract(g.members);store.petViews=store.petViews.filter{!g.members.contains($0.key)}
            groupSeats(g.members,circle:true)
            for id in g.members{store.act(.sit,id:id);store.affect(.play,id:id);store.sceneIcons[id]=["🌟","🎈","🍀","🫧","🌼","🎶","👏","✨"][(id+g.round)%8]}
            if g.settings.kind == .rps{
                for id in g.members{g.hands[id]=Int.random(in:0..<3);store.heldItems[id]=["✊","✋","✌️"][g.hands[id]!]}
                var results:[String]=[]
                for i in stride(from:0,to:g.members.count-1,by:2){let a=g.members[i],b=g.members[i+1],result=GameRules.result(g.hands[a]!,g.hands[b]!);if result != 0{let winner=result>0 ? a:b;g.scores[winner,default:0]+=1;results.append(store.petName(winner)+"赢这一轮") }else{results.append("平局，再来一轮～")};store.befriend(a,b,amount:3)}
                if let id=g.members.first{store.say(results.joined(separator:"；"),id:id,duration:5)}
            }else{store.say(g.settings.kind == .hide ? "我来找，先数到三！":g.settings.kind == .karaoke ? "这首歌送给一起努力的你～":"准备好，大家轮流来！",id:lead,duration:4)}
        }
        switch g.settings.kind {
        case .hide:
            let others=g.members.filter{$0 != lead};store.petViews[lead]=elapsed<3 ? "back":"side"
            if elapsed<3{for id in others{store.hiddenPets.insert(id)};store.act(.sit,id:lead)}
            else{
                let found=min(others.count,Int((elapsed-3)/max(1,(duration-4)/Double(others.count)))+1)
                for (i,id) in others.enumerated(){if i<found{store.hiddenPets.remove(id);if !g.revealed.contains(id){g.revealed.insert(id);store.say("找到啦！一起笑一笑～",id:id,duration:3);store.befriend(lead,id)}}}
                if let target=others.last(where:{g.revealed.contains($0)}),let panel=pets[target],let stage=stageWindow{stageSeat(NSPoint(x:panel.frame.midX-stage.frame.minX-24,y:panel.frame.minY-stage.frame.minY),id:lead)}
                gamePose(.look,id:lead)
            }
        case .cloth:
            let angle=progress*Double.pi*2,receiver=g.members[(g.round+1)%g.members.count]
            if progress<0.66{stageSeat(NSPoint(x:165+cos(angle)*120,y:33+sin(angle)*30),id:lead);gamePose(.walk,id:lead);store.heldItems[lead]="🧣"}
            else{store.heldItems.removeValue(forKey:lead);store.heldItems[receiver]="🧣";gamePose(.walk,id:receiver);stageSeat(NSPoint(x:165+cos(angle-0.4)*120,y:33+sin(angle-0.4)*30),id:receiver);stageSeat(NSPoint(x:165+cos(angle)*120,y:33+sin(angle)*30),id:lead)}
        case .eagle:
            let protect=g.members[(g.round+1)%g.members.count],chicks=g.members.filter{$0 != lead && $0 != protect},wave=sin(progress*Double.pi*2)
            store.sceneIcons[lead]="🦅";store.sceneIcons[protect]="🛡️";for id in chicks{store.sceneIcons[id]="🐥"}
            stageSeat(NSPoint(x:140+wave*25,y:30),id:protect);gamePose(.wave,id:protect)
            for (i,id) in chicks.enumerated(){stageSeat(NSPoint(x:170+Double(i)*18+sin(progress*6-Double(i)*0.3)*16,y:31+Double(i%2)*8),id:id);gamePose(.walk,id:id)}
            stageSeat(NSPoint(x:65+sin(progress*6+0.5)*28,y:30+cos(progress*6)*12),id:lead);gamePose(.walk,id:lead)
        case .rps:break
        case .hop:
            groupSeats(g.members.filter{$0 != lead},circle:false);let cell=min(6,Int(progress*7));stageSeat(NSPoint(x:37+Double(cell)*40,y:18+Double(cell%2)*5),id:lead);gamePose(.jump,id:lead)
        case .karaoke:
            stageSeat(NSPoint(x:165,y:38),id:lead);store.heldItems[lead]="🎤";gamePose(.talk,id:lead)
            for id in g.members where id != lead{store.act(.sit,id:id)}
        }
        if elapsed>=duration{
            for id in g.members where id != lead{store.befriend(lead,id,amount:2)}
            g.round+=1;g.started=now;g.announced=false
            if g.round>=max(1,g.settings.rounds){
                if g.settings.kind == .rps,let best=g.scores.max(by:{$0.value<$1.value}){store.gameStatus="\(store.petName(best.key))得到 \(best.value) 分，大家都很棒！"}
                game=g;let final=store.gameStatus;endGame();store.gameStatus=final+" · 已结束";return
            }
        }
        game=g
    }

}

enum Food:String,Codable,CaseIterable,Identifiable {
    case rice="小饭团",carrot="胡萝卜饼",berry="草莓",nuts="坚果饼",brownie="布朗尼",fruit="水果拼盘",milk="温牛奶"
    var id:String{rawValue}
    var emoji:String{switch self{case .rice:return "🍙";case .carrot:return "🥕";case .berry:return "🍓";case .nuts:return "🥜";case .brownie:return "🍫";case .fruit:return "🍎";case .milk:return "🥛"}}
    static func favorite(_ id:Int)->Food{[.rice,.carrot,.rice,.berry,.nuts,.brownie,.rice,.fruit][id]}
}
enum GameKind:String,Codable,CaseIterable,Identifiable {
    case hide="捉迷藏",cloth="丢手绢",eagle="老鹰捉小鸡",rps="石头剪刀布",hop="跳格子",karaoke="K歌"
    var id:String{rawValue}
    var rules:String{switch self{
    case .hide:return "轮流当寻找者：倒数后出发，找到所有藏起来的伙伴完成一轮。"
    case .cloth:return "围圈坐好，一只绕圈跑、放下手绢；拿到手绢的伙伴追赶并接棒。"
    case .eagle:return "一只当老鹰，一只保护小鸡；小鸡跟随保护者，老鹰寻找机会靠近队尾。"
    case .rps:return "两两出拳：石头赢剪刀，剪刀赢布，布赢石头；相同则平局。"
    case .hop:return "轮流沿侧视格子单脚跳到终点，其余伙伴在旁边加油。"
    case .karaoke:return "轮流拿麦克风上台，其他伙伴坐好听歌、跟拍和鼓掌。"}}
    var minimum:Int{self == .eagle ? 3:self == .hop || self == .karaoke ? 1:2}
}
struct GameSettings:Codable {
    var kind:GameKind = .hide
    var rounds=4
    var seconds=12
    var title=""
    var customRules=""
}
struct GameSession {
    let settings:GameSettings
    let members:[Int]
    var round=0
    var started=Date()
    var announced=false
    var revealed:Set<Int>=[]
    var hands:[Int:Int]=[:]
    var scores:[Int:Int]=[:]
}
enum GameRules {
    static func result(_ a:Int,_ b:Int)->Int{a==b ? 0:((a-b+3)%3==1 ? 1:-1)} // rock=0 paper=1 scissors=2
    static func seats(count:Int,center:NSPoint,rx:Double,ry:Double)->[NSPoint]{
        (0..<count).map{i in let angle=Double(i)/Double(max(1,count))*2*Double.pi;return NSPoint(x:center.x+cos(angle)*rx,y:center.y+sin(angle)*ry)}
    }
}
@MainActor final class StudyAudio:ObservableObject {
    @Published var label="未播放"
    @Published var volume:Double=0.28{didSet{sound?.volume=Float(volume)}}
    var sound:NSSound?
    func choose(){
        let panel=NSOpenPanel();panel.allowedContentTypes=[.audio];panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let url=panel.url else{return}
        sound?.stop();sound=NSSound(contentsOf:url,byReference:false);sound?.loops=true;sound?.volume=Float(volume)
        label=sound?.play()==true ? url.lastPathComponent:"这个音频无法播放，请换一个文件。"
    }
    func playOriginal(){
        guard let url=Bundle.main.resourceURL?.appendingPathComponent("study-garden.wav") else{return}
        sound?.stop();sound=NSSound(contentsOf:url,byReference:false);sound?.loops=true;sound?.volume=Float(volume);label=sound?.play()==true ? "原创轻音乐 · 小园微光":"无法播放内置音乐"
    }
    func stop(){sound?.stop();label="已停止"}
}
struct RoomDecor:View {
    let id:Int
    var body:some View {
        ZStack{
            RoundedRectangle(cornerRadius:4).fill([Color.blue,Color.mint,Color.pink,Color.purple,Color.orange,Color.yellow,Color.teal,Color.brown][id].opacity(0.15))
            VStack(spacing:0){HStack{Text(["🌙","🪴","🏋️","🎨","🎸","☀️","📚","🌿"][id]).font(.system(size:9));Spacer()};Spacer();HStack(spacing:2){RoundedRectangle(cornerRadius:2).fill(Color.white.opacity(0.75)).frame(width:14,height:7);Text(["⭐️","🥕","💪","🖌","🎧","🧁","☕️","🦊"][id]).font(.system(size:7))}}
            .padding(3)
        }
    }
}
struct MiniStage:View {
    let kind:String
    var label:String=""
    var body:some View {
        ZStack(alignment:.bottom){
            Canvas{ctx,size in
                let w=size.width,h=size.height
                func box(_ rect:CGRect,_ color:Color,_ radius:Double=8){ctx.fill(Path(roundedRect:rect,cornerRadius:radius),with:.color(color))}
                if kind==GameKind.hop.rawValue {
                    for i in 0..<7 {
                        let x=18+Double(i)*40,y=h-42-Double(i%2)*5,color:Color=i%2==0 ? .mint:.yellow
                        var top=Path();top.move(to:CGPoint(x:x,y:y));top.addLine(to:CGPoint(x:x+31,y:y));top.addLine(to:CGPoint(x:x+38,y:y+12));top.addLine(to:CGPoint(x:x+7,y:y+12));top.closeSubpath();ctx.fill(top,with:.color(color.opacity(0.5)));ctx.stroke(top,with:.color(.white),lineWidth:1)
                        var edge=Path();edge.move(to:CGPoint(x:x+7,y:y+12));edge.addLine(to:CGPoint(x:x+38,y:y+12));edge.addLine(to:CGPoint(x:x+38,y:y+19));edge.addLine(to:CGPoint(x:x+7,y:y+19));edge.closeSubpath();ctx.fill(edge,with:.color(color.opacity(0.75)))
                        ctx.draw(Text("\(i+1)").font(.system(size:9)).foregroundStyle(.brown),at:CGPoint(x:x+19,y:y+6))
                    }
                }else if kind==Scenario.study.rawValue {
                    box(CGRect(x:8,y:12,width:w-16,height:h-20),.mint.opacity(0.08));for i in 0..<4{box(CGRect(x:18+Double(i)*76,y:h-45,width:62,height:9),.brown.opacity(0.30),3)}
                    ctx.draw(Text("📖  安静自习角").font(.system(size:11)),at:CGPoint(x:w/2,y:12))
                }else if kind==Scenario.picnic.rawValue {
                    box(CGRect(x:22,y:h-72,width:w-44,height:59),.pink.opacity(0.19));for i in 0..<9{let x=24+Double(i)*32;ctx.stroke(Path(CGRect(x:x,y:h-72,width:1,height:59)),with:.color(.white.opacity(0.8)),lineWidth:2)}
                    ctx.draw(Text("🧺").font(.system(size:21)),at:CGPoint(x:38,y:h-32))
                }else if kind==GameKind.karaoke.rawValue || kind==Scenario.party.rawValue {
                    box(CGRect(x:16,y:h-45,width:w-32,height:24),.purple.opacity(0.22));ctx.draw(Text("♫  LittleCompanions LIVE  ♫").font(.system(size:12,weight:.bold)).foregroundStyle(.purple),at:CGPoint(x:w/2,y:16));for x in [20.0,w-20]{box(CGRect(x:x-8,y:h-82,width:16,height:33),.indigo.opacity(0.5),4)}
                }else if kind==GameKind.hide.rawValue {
                    for x in [26.0,w/2,w-30]{ctx.draw(Text("🌳").font(.system(size:36)),at:CGPoint(x:x,y:h-44))}
                }else if kind==GameKind.cloth.rawValue || kind==GameKind.rps.rawValue {
                    let rect=CGRect(x:w/2-86,y:h-81,width:172,height:61);ctx.fill(Path(ellipseIn:rect),with:.color(.orange.opacity(0.14)));ctx.stroke(Path(ellipseIn:rect),with:.color(.orange.opacity(0.3)),style:StrokeStyle(lineWidth:1,dash:[3,4]))
                }else{box(CGRect(x:8,y:h-46,width:w-16,height:28),.green.opacity(0.12));ctx.draw(Text("🌿").font(.system(size:20)),at:CGPoint(x:22,y:h-50))}
            }
            if !label.isEmpty{Text(label).font(.system(size:9)).foregroundStyle(.secondary).padding(.bottom,1).lineLimit(1)}
        }.frame(width:330,height:148)
    }
}

struct ActivityControls:View {
    @ObservedObject var store:Store
    @ObservedObject var audio:StudyAudio
    var body:some View {
        VStack(alignment:.leading,spacing:10){
            Text("玩耍模式").font(.headline)
            HStack{Picker("游戏",selection:$store.gameSettings.kind){ForEach(GameKind.allCases){Text($0.rawValue).tag($0)}};Stepper("\(store.gameSettings.rounds) 轮",value:$store.gameSettings.rounds,in:1...12).frame(width:140)}
            Text(store.gameSettings.kind.rules).font(.caption).foregroundStyle(.secondary)
            Stepper("每轮 \(store.gameSettings.seconds) 秒",value:$store.gameSettings.seconds,in:8...40,step:2)
            TextField("自定义游戏名称（可选）",text:$store.gameSettings.title).textFieldStyle(.roundedBorder)
            TextField("补充游戏规则，例如：轮流当寻找者、不淘汰伙伴",text:$store.gameSettings.customRules,axis:.vertical).lineLimit(2...3).textFieldStyle(.roundedBorder)
            Text("自定义名称与规则会展示在游戏场景；动作流程按上方选择的游戏模板执行。K歌可导入伴奏，当前不合成人声。").font(.caption2).foregroundStyle(.secondary)
            HStack{Button("开始玩耍"){store.persist();store.playGame?()}.buttonStyle(.borderedProminent);Button("结束游戏"){store.stopGame?()};Text(store.gameStatus).font(.caption).lineLimit(2)}
            Divider();Text("学习模式 · 番茄钟").font(.headline)
            HStack{Stepper("专注 \(store.focusMinutes) 分",value:$store.focusMinutes,in:1...90);Text("计时结束后自动结束本轮").font(.caption).foregroundStyle(.secondary)}
            HStack{Button("开始学习"){store.startScene?(.study)};Button("结束学习"){store.stopScene?()};Button(store.pomodoroRunning ? "暂停计时":"继续计时"){store.pomodoroRunning.toggle();store.pomodoroLast=Date()}.disabled(!store.activityLocked.isEmpty && store.sceneName != Scenario.study.rawValue || store.sceneName.isEmpty);Text("\(store.onStudyBreak ? "休息":"专注") \(store.pomodoroRemaining/60):\(String(format:"%02d",store.pomodoroRemaining%60))").monospacedDigit()}
            Text("整间自习室可一起拖动；拖动、聊天或切换窗口不会结束学习。只有本轮计时结束或点击结束学习才退出。").font(.caption).foregroundStyle(.secondary)
            HStack{Button("导入纯音乐"){audio.choose()};Button("停止音乐"){audio.stop()};Button("原创轻音乐"){audio.playOriginal()}}
            HStack{Text(audio.label).font(.caption).foregroundStyle(.secondary);Spacer();Text("音量").font(.caption);Slider(value:$audio.volume,in:0...1).frame(width:100)}
        }.padding(12).background(.white,in:RoundedRectangle(cornerRadius:14))
    }
}

struct StudyHandle:NSViewRepresentable {
    var store:Store
    func makeNSView(context:Context)->StudyHandleView{let v=StudyHandleView();v.store=store;return v}
    func updateNSView(_ view:StudyHandleView,context:Context){view.store=store}
}
@MainActor final class StudyHandleView:NSView {
    weak var store:Store?;var start=NSPoint.zero
    override var mouseDownCanMoveWindow:Bool{false}
    override func acceptsFirstMouse(for event:NSEvent?)->Bool{true}
    override func mouseDown(with event:NSEvent){start=NSEvent.mouseLocation;store?.dragStudy?(.zero,false)}
    override func mouseDragged(with event:NSEvent){let p=NSEvent.mouseLocation;store?.dragStudy?(CGSize(width:p.x-start.x,height:start.y-p.y),false)}
    override func mouseUp(with event:NSEvent){let p=NSEvent.mouseLocation;store?.dragStudy?(CGSize(width:p.x-start.x,height:start.y-p.y),true)}
}
struct StageHost:View {
    @ObservedObject var store:Store
    var body:some View {
        MiniStage(kind:store.stageKind,label:store.stageLabel).overlay(alignment:.top){
            if store.stageKind==Scenario.study.rawValue {
                HStack(spacing:4){Text("↔ 自习室 \(store.pomodoroRemaining/60):\(String(format:"%02d",store.pomodoroRemaining%60)) · 拖动移动").font(.system(size:10)).frame(maxWidth:.infinity).frame(height:24).background(.regularMaterial,in:Capsule()).overlay(StudyHandle(store:store));Button("结束学习"){store.stopScene?()}.font(.system(size:10)).buttonStyle(.bordered)}.frame(height:24)
            }
        }
    }
}
extension AppDelegate {
    func comfort(_ id:Int){
        guard !store.housed.contains(id),scene==nil,game==nil,!store.busy.contains(id) else{return}
        if social != nil{return}
        let friends=store.activePets.filter{$0 != id && !store.busy.contains($0) && store.actions[$0] != .sleep && dragOrigins[$0]==nil}
        guard let friend=friends.max(by:{store.bond(id,$0)<store.bond(id,$1)}) else{return}
        store.say("别难过，我来抱抱你。",id:friend,duration:4)
        store.actions[id] = .idle;store.actions[friend] = .idle
        startSocial(preferred:id,force:true,kind:4,partner:friend)
    }
}
func activityPreview(kind:String)->some View {
    VStack(alignment:.leading,spacing:2){
        Text(kind).font(.system(size:13,weight:.semibold)).foregroundStyle(.indigo)
        ZStack(alignment:.topLeading){
            MiniStage(kind:kind)
            ForEach(0..<4,id:\.self){id in
                let reading=kind==Scenario.study.rawValue,eating=kind==Scenario.picnic.rawValue,singing=kind==GameKind.karaoke.rawValue
                let point:CGPoint=kind==GameKind.hop.rawValue ? CGPoint(x:Double(id)*59+55,y:id==0 ? 85:49):CGPoint(x:Double(id)*70+55,y:id%2==0 ? 70:85)
                PetArt(character:Character.all[id],action:reading ? .read:eating ? .eat:singing ? (id==1 ? .talk:.sit):id==0 ? .jump:.wave,time:1.7,expression:.happy,held:reading ? "📖":eating ? ["🍓","🍙","🥕","🍎"][id]:singing && id==1 ? "🎤":nil).frame(width:64,height:70).position(point)
            }
        }.frame(width:330,height:148).background(.white.opacity(0.7),in:RoundedRectangle(cornerRadius:13))
    }
}

if CommandLine.arguments.contains("--self-test") {
    do{
        precondition(Character.all.count==8)
        precondition(Set(Character.all.map(\.name)).count==8)
        precondition(Set(Character.all.map(\.persona)).count==8)
        precondition(Action.allCases.count>=8)
        precondition(!SocialRules.canJoin(.sleep,busy:false,dragging:false))
        precondition(!SocialRules.canJoin(.idle,busy:true,dragging:false))
        precondition(!SocialRules.canJoin(.idle,busy:false,dragging:true))
        precondition(SocialRules.canJoin(.idle,busy:false,dragging:false))
        var growth=CareProfile();precondition(growth.outfit == .none && growth.xp==0 && growth.stage==0)
        let today=Date(),tomorrow=Calendar.current.date(byAdding:.day,value:1,to:today)!
        precondition(growth.award(20,at:today)==12);precondition(growth.award(3,at:today)==0)
        precondition(growth.award(4,at:tomorrow)==4)
        growth.xp=35;precondition(!growth.canWear(.scarf));growth.xp=36;precondition(growth.stage==1 && growth.canWear(.scarf) && !growth.canWear(.hoodie))
        growth.xp=24;precondition(growth.canWear(.bib) && !growth.canWear(.whiteSet))
        growth.xp=72;precondition(growth.canWear(.whiteSet) && !growth.canWear(.picnic))
        growth.xp=160;precondition(growth.canWear(.picnic));growth.xp=240;precondition(growth.canWear(.pinkSet))
        growth.xp=120;precondition(growth.stage==2 && growth.canWear(.hoodie));growth.xp=300;precondition(growth.stage==3 && growth.canWear(.pajamas))
        let legacy=try JSONDecoder().decode(SavedState.self,from:Data("{\"visible\":[0],\"chats\":{},\"schedules\":[],\"positions\":{}}".utf8));precondition(legacy.care==nil)

        let openai:[String:Any] = ["output":[["type":"reasoning","summary":[]],["type":"message","content":[["type":"output_text","text":"你好"]]]]]
        let text1=try ChatAPI.decode(openai,openai:true);precondition(text1=="你好")
        let text2=try ChatAPI.decode(["choices":[["message":["content":"你好 DeepSeek"]]]],openai:false);precondition(text2=="你好 DeepSeek")
        do{_ = try ChatAPI.decode([:],openai:true);fatalError("Empty response must fail")}catch{}
        let state=SavedState(visible:[0,2,7],chats:["0":[Message(role:"user",text:"测试")]],schedules:[Schedule(title:"测试日程",date:Date())],positions:["0":[10,20]])
        let roundtrip=try JSONDecoder().decode(SavedState.self,from:JSONEncoder().encode(state));precondition(roundtrip.visible==[0,2,7]);precondition(roundtrip.chats["0"]?.first?.text=="测试")
        print("PASS: characters, actions, API parsing, empty responses, persistence, initial bare outfit, daily growth cap, day rollover, stage and clothing unlocks, legacy save migration")
        exit(0)
    }catch{fputs("Self-test failed\n",stderr);exit(1)}
}
if CommandLine.arguments.contains("--logic-test") {
    MainActor.assumeIsolated {
        guard ProcessInfo.processInfo.environment["LITTLECOMPANIONS_DATA_DIR"] != nil else {exit(1)}
        let store=Store();store.schedules=[];store.chats=[:];store.showAll()
        precondition(store.visible.count==8)
        store.visible=[0,3,7];precondition(store.visible.count==3)
        store.toggle(3);precondition(store.visible==[0,7]);store.hideAll();precondition(store.visible.isEmpty)
        store.visible=[1];precondition(store.visible.count==1)
        store.act(.sleep,id:1);store.act(.walk,id:2);precondition(store.actions[1] == .sleep && store.actions[2] == .walk)
        store.schedules=[Schedule(title:"到点提醒",date:Date().addingTimeInterval(-1)),Schedule(title:"未来",date:Date().addingTimeInterval(600)),Schedule(title:"完成",date:Date().addingTimeInterval(-1),done:true)]
        store.remind();precondition(store.schedules[0].reminded && !store.schedules[1].reminded && !store.schedules[2].reminded)
        precondition(store.bubbles[1]?.contains("到点提醒")==true)
        store.chats=["0":[Message(role:"user",text:"狼的记录")],"7":[Message(role:"user",text:"狐狸的记录")]];store.persist()
        let restored=Store();precondition(restored.chats["0"]?.first?.text=="狼的记录" && restored.chats["7"]?.first?.text=="狐狸的记录")
        precondition(abs(pow(sqrt(0.1),2)-0.1)<0.00001)
        store.care["0"]=CareProfile();store.feed(0);precondition(store.profile(0).xp==3)
        store.feed(0);precondition(store.profile(0).xp==3)
        store.teach("我喜欢画画",id:0);precondition(store.profile(0).lessons==["我喜欢画画"] && store.profile(0).xp==7)
        store.teach("我喜欢画画",id:0);precondition(store.profile(0).xp==7)
        store.dress(.hoodie,id:0);precondition(store.profile(0).outfit == .none)
        var unlocked=store.profile(0);unlocked.xp=36;store.care["0"]=unlocked
        store.dress(.bib,id:0);precondition(store.profile(0).outfit == .bib)
        store.persist();let careReload=Store();precondition(careReload.profile(0).outfit == .bib && careReload.profile(0).lessons==["我喜欢画画"])

        store.setAccessory(.bow,id:0);store.setMood(.sad,id:0);store.persist()
        let dressedReload=Store();precondition(dressedReload.profile(0).accessory == .bow && dressedReload.profile(0).mood == .sad)
        store.setAccessory(.glasses,id:0);precondition(store.profile(0).accessory == .bow)
        print("PASS: 8 / subset / single / none selections, independent actions, reminder timing, character chat isolation, disk persistence, 1/10 area scaling, feed cooldown, learning deduplication, locked wardrobe, clothing persistence")
    }
    exit(0)
}
MainActor.assumeIsolated {
    if let i=CommandLine.arguments.firstIndex(of:"--verify-release"),CommandLine.arguments.count>i+2 {
        do {
            let config=try JSONDecoder().decode(UpdateConfiguration.self,from:Data(contentsOf:Bundle.main.url(forResource:"UpdateConfig",withExtension:"json")!))
            let bytes=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[i+1]))
            guard let pair=try UpdatePolicy.verify(bytes,key:config.publicKey,current:"0.8.0") else{throw UpdateFailure.invalid("没有新版本")}
            try UpdatePolicy.verifyFile(URL(fileURLWithPath:CommandLine.arguments[i+2]),artifact:pair.1)
            print("PASS: native Mac pinned public key, downloaded release signature, version, size and SHA-256 verified for \(pair.0.version)")
        }catch{fputs("Release verification failed: \(error)\n",stderr);exit(1)}
        exit(0)
    }
    if CommandLine.arguments.contains("--creator-test") {
        guard ProcessInfo.processInfo.environment["LITTLECOMPANIONS_DATA_DIR"] != nil else{exit(1)}
        let library=DesignLibrary.shared;var d=PetDesign();d.shape="droplet";d.ears="leaf";d.color="#c3d8eb";d.persona="喜欢画画";library.save(d,id:0)
        precondition(DesignLibrary().design(0).persona=="喜欢画画")
        var bad=PetDesign();bad.color="url(file:///etc/passwd)";bad.shape="script";bad.images=["neutral":"data:image/svg+xml;base64,bad"];precondition(bad.normalized().images.isEmpty);precondition(bad.normalized().shape=="bean")
        let file=CharacterFile(name:"我的小水滴",design:d);let bytes=try! JSONEncoder().encode(file);let back=try! JSONDecoder().decode(CharacterFile.self,from:bytes);precondition(back.design.normalized().shape=="droplet");precondition(!String(data:bytes,encoding:.utf8)!.contains("chats"))
        let dir=URL(fileURLWithPath:ProcessInfo.processInfo.environment["LITTLECOMPANIONS_DATA_DIR"]!)
        if let data=try? Data(contentsOf:dir.appendingPathComponent("character-js.json")) {let imported=try! JSONDecoder().decode(CharacterFile.self,from:data);precondition(imported.design.normalized().images["neutral"] != nil);library.save(imported.design,id:1)}
        let encoder=JSONEncoder();try! encoder.encode(CharacterFile(name:"Mac 创建的小伙伴",design:library.design(1))).write(to:dir.appendingPathComponent("character-mac.json"))
        print("PASS: custom design persistence, JSON round trip, shape/color/image validation and private-data-free export");exit(0)
    }
    let app=NSApplication.shared
    if let i=CommandLine.arguments.firstIndex(of:"--render-creator"),CommandLine.arguments.count>i+1 {
        let store=Store();let view=MainView(store:store,tab:6).frame(width:1100,height:800)
        let renderer=ImageRenderer(content:view);renderer.scale=1.5
        guard let image=renderer.nsImage,let tiff=image.tiffRepresentation,let rep=NSBitmapImageRep(data:tiff),let png=rep.representation(using:.png,properties:[:]) else{exit(1)}
        try! png.write(to:URL(fileURLWithPath:CommandLine.arguments[i+1]));print("Creator preview rendered");exit(0)
    }
    if let index=CommandLine.arguments.firstIndex(of:"--update-test"),CommandLine.arguments.count>index+1 {
        let root=URL(fileURLWithPath:CommandLine.arguments[index+1])
        do {
            let key=try String(contentsOf:root.appendingPathComponent("public-key.txt"),encoding:.utf8)
            let data=try Data(contentsOf:root.appendingPathComponent("valid.json"))
            let pair=try UpdatePolicy.verify(data,key:key)!;precondition(pair.0.version=="0.7.1")
            try UpdatePolicy.verifyFile(root.appendingPathComponent("archive.zip"),artifact:pair.1)
            let old=try UpdatePolicy.verify(data,key:key,current:"0.8.1");precondition(old==nil)
            var refused=false;do{_ = try UpdatePolicy.verify(Data(contentsOf:root.appendingPathComponent("invalid.json")),key:key)}catch{refused=true};precondition(refused)
            refused=false;do{_ = try UpdatePolicy.https("http://example.test/latest.json")}catch{refused=true};precondition(refused)
            try UpdateManager.helper.write(to:root.appendingPathComponent("apply-update.sh"),atomically:true,encoding:.utf8)
            print("PASS: cross-platform signed manifest, invalid signature and downgrade rejection, HTTPS and downloaded file hash validation")
            exit(0)
        }catch{fatalError("Update validation failed: \(error)")}
    }
    if let index=CommandLine.arguments.firstIndex(of:"--render-ball"),CommandLine.arguments.count>index+1 {
        let folder=URL(fileURLWithPath:CommandLine.arguments[index+1]);try! FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        for frame in 0..<100 {
            let t=Double(frame)/20,sample=BallMotion.sample(t),progress=sample.forward ? sample.travel:1-sample.travel
            let missed=Int(t/1.65)%3==2 ? min(1,max(0,(sample.phase-0.25)/0.45))*13:0
            let ax=110.0+(sample.forward ? 0:-missed),bx=350.0+(sample.forward ? missed:0)
            let view=ZStack {
                Color(red:0.97,green:0.95,blue:0.98)
                Text("轮流踢球 · 弹跳传球 · 挪步接球").font(.system(size:17,weight:.semibold)).position(x:230,y:23)
                RoundedRectangle(cornerRadius:4).fill(Color.green.opacity(0.12)).frame(width:380,height:8).position(x:230,y:186)
                PetArt(character:Character.all[0],action:sample.forward && sample.phase<0.28 ? .kick:.look,time:t).frame(width:110,height:120).position(x:ax,y:132)
                PetArt(character:Character.all[4],action:!sample.forward && sample.phase<0.28 ? .kick:.look,time:t).frame(width:110,height:120).position(x:bx,y:132)
                SoccerBall(rotation:t*220,lift:sample.lift).position(x:ax+22+(bx-ax-44)*progress,y:164)
                Text("实际角色绘制与传球轨迹预览").font(.system(size:11)).foregroundStyle(.secondary).position(x:230,y:217)
            }.frame(width:460,height:240)
            let renderer=ImageRenderer(content:view);renderer.scale=1.5
            let rep=NSBitmapImageRep(cgImage:renderer.cgImage!);try! rep.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent(String(format:"%03d.png",frame)))
        }
        print("100 ball preview frames rendered");exit(0)
    }
    if CommandLine.arguments.contains("--ball-test") {
        let a=BallMotion.sample(0),b=BallMotion.sample(1.5),c=BallMotion.sample(1.7)
        precondition(a.forward && a.travel==0 && b.travel==1 && !c.forward)
        for i in 0..<165{let t=Double(i)/100,sample=BallMotion.sample(t);precondition(sample.travel>=0 && sample.travel<=1 && sample.lift>=0);if i>0{let last=BallMotion.sample(t-0.01);precondition(abs(last.travel-sample.travel)<0.04)}}
        precondition(BallMotion.sample(0.8).lift>0)
        print("PASS: held wind-up, continuous two-way ball passes, bounce and receiving pause")
        exit(0)
    }
    if CommandLine.arguments.contains("--arm-test") {
        var count=0
        for id in 0..<8 {for action in [Action.wave,.jump,.hug,.dance,.special,.read,.sit,.eat,.kick] {for sample in 0..<24 {
            let view=PetArt(character:Character.all[id],action:action,time:Double(sample)/24*5,outfit:[Outfit.none,.whiteSet,.picnic][sample%3],expression:.happy).frame(width:170,height:185).padding(50)
            let renderer=ImageRenderer(content:view);renderer.scale=1
            guard let image=renderer.cgImage else{fatalError("Arm render failed")}
            let w=image.width,h=image.height;var data=[UInt8](repeating:0,count:w*h*4)
            data.withUnsafeMutableBytes{p in let c=CGContext(data:p.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;c.draw(image,in:CGRect(x:0,y:0,width:w,height:h))}
            var seen=Set<Int>(),areas=[Int]()
            for start in 0..<(w*h) where data[start*4+3]>100 && !seen.contains(start) {
                var queue=[start],cursor=0;seen.insert(start)
                while cursor<queue.count {let i=queue[cursor];cursor+=1
                    for next in [i%w>0 ? i-1:-1,i%w<w-1 ? i+1:-1,i>=w ? i-w:-1,i+w<w*h ? i+w:-1] where next>=0 {
                        if data[next*4+3]>100 && !seen.contains(next){seen.insert(next);queue.append(next)}
                    }
                }
                if queue.count>8{areas.append(queue.count)}
            }
            precondition(areas.count==1,"Detached body component: id=\(id) action=\(action) frame=\(sample) areas=\(areas)")
            count+=1
        }}}
        print("PASS: \(count) arm animation frames (bare and two outfits) contain one connected pet silhouette, with no detached limb fragments")
        exit(0)
    }
    if let i=CommandLine.arguments.firstIndex(of:"--render-arms"),CommandLine.arguments.count>i+1 {
        let view=VStack(spacing:14){
            Text("手臂衔接修复 · 挥手 / 抱抱 / 跳舞 / 拿书").font(.title2.bold())
            ForEach(0..<2,id:\.self){row in HStack(spacing:8){ForEach(0..<4,id:\.self){col in
                let id=row*4+col
                VStack{Text(Character.all[id].name).font(.caption);PetArt(character:Character.all[id],action:[Action.wave,.hug,.dance,.read][col],time:1.2).frame(width:155,height:172).padding(16)}.background(Color.white,in:RoundedRectangle(cornerRadius:16))
            }}}
            HStack(spacing:8){ForEach(0..<4,id:\.self){col in
                VStack{Text("挥手 \(col+1)").font(.caption);PetArt(character:Character.all[0],action:.wave,time:Double(col)*0.19).frame(width:155,height:172).padding(16)}.background(Color.white,in:RoundedRectangle(cornerRadius:16))
            }}
        }.padding(20).background(Color(red:0.96,green:0.94,blue:0.97))
        let renderer=ImageRenderer(content:view);renderer.scale=2
        if let cg=renderer.cgImage{let rep=NSBitmapImageRep(cgImage:cg);try! rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[i+1]))}
        exit(0)
    }
    if CommandLine.arguments.contains("--motion-test") {
        var count=0
        for scale in [0.22,sqrt(0.1),0.5,0.8,0.92] {for id in 0..<8 {for action in [Action.jump,.fly,.hug,.special,.dance] {for sample in 0..<16 {
            let t=Double(sample)/16*4,base=MotionLayout.base(scale)
            let view=PetArt(character:Character.all[id],action:action,time:t,expression:.happy).frame(width:170*scale,height:185*scale).rotationEffect(.degrees(action == .hug ? 12:0),anchor:.bottom).frame(width:base.width,height:base.height,alignment:.top).padding(EdgeInsets(top:MotionLayout.top,leading:MotionLayout.side,bottom:0,trailing:MotionLayout.side))
            let renderer=ImageRenderer(content:view);renderer.scale=1
            guard let image=renderer.cgImage else{fatalError("render failed")}
            let w=image.width,h=image.height;var data=[UInt8](repeating:0,count:w*h*4)
            data.withUnsafeMutableBytes {p in let ctx=CGContext(data:p.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;ctx.draw(image,in:CGRect(x:0,y:0,width:w,height:h))}
            for y in 0..<h{for x in 0..<w where x<2 || y<2 || x>=w-2 || y>=h-2 {
                precondition(data[(y*w+x)*4+3]<24,"Clipped \(id) \(action) scale=\(scale) t=\(t) x=\(x) y=\(y)")
            }}
            count+=1
        }}}}
        let bounds=NSRect(origin:.zero,size:MotionLayout.window(sqrt(0.1)))
        precondition(!MotionLayout.hitRegion(bounds).contains(NSPoint(x:2,y:10)))
        precondition(MotionLayout.hitRegion(bounds).contains(NSPoint(x:bounds.midX,y:40)))
        precondition(!MotionLayout.hitRegion(bounds).contains(NSPoint(x:bounds.midX,y:bounds.maxY-2)))
        print("PASS: \(count) motion frames keep ears, limbs and bodies inside the transparent window at five scales including maximum growth")
        exit(0)
    }
    if let index=CommandLine.arguments.firstIndex(of:"--render-motion"),CommandLine.arguments.count>index+1 {
        let view=VStack(spacing:12){Text("蹦跳不削耳 · 动作边界修复").font(.title2.bold()).foregroundStyle(.indigo);Text("保持小动物大小，给动作预留透明空间").font(.caption).foregroundStyle(.secondary)
            HStack(spacing:6){ForEach(0..<8,id:\.self){id in
                let scale=0.5,base=MotionLayout.base(scale),time=(Double.pi/6-Double(id)*1.71)/2.3
                PetArt(character:Character.all[id],action:.jump,time:time).frame(width:170*scale,height:185*scale).frame(width:base.width,height:base.height,alignment:.top).padding(EdgeInsets(top:MotionLayout.top,leading:MotionLayout.side,bottom:0,trailing:MotionLayout.side)).background(.white,in:RoundedRectangle(cornerRadius:12))
            }}
        }.padding(22).background(Color(red:0.97,green:0.95,blue:0.99))
        let renderer=ImageRenderer(content:view);renderer.scale=1.5
        let rep=NSBitmapImageRep(cgImage:renderer.cgImage!);try! rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[index+1]));print("motion preview rendered");exit(0)
    }
    if CommandLine.arguments.contains("--v06-test") {
        guard ProcessInfo.processInfo.environment["LITTLECOMPANIONS_DATA_DIR"] != nil else{exit(1)}
        let h=AppDelegate();h.store.housed=[];h.store.care=[:];h.store.bonds=[:];h.layoutBoundsOverride=NSRect(x:0,y:-18,width:1440,height:900);h.store.visible=Set(0..<8)
        for id in 0..<8{h.pets[id]=PetPanel(contentRect:NSRect(x:150+Double(id)*45,y:10,width:74,height:84),styleMask:.borderless,backing:.buffered,defer:false)}
        h.store.care["0"]=CareProfile();h.store.setMood(.sad,id:0);precondition(h.store.expression(0) == .sad)
        h.store.moodUntil[0]=Date().addingTimeInterval(-1);h.store.sadnessBegan[0]=Date().addingTimeInterval(-8);h.store.updateFeelings();precondition(h.store.expression(0) != .sad)
        h.store.lastMoodEvent=[:];h.store.affect(.hurt,id:0);precondition(h.store.expression(0) == .sad);h.store.affect(.friend,id:0);precondition(h.store.expression(0) == .happy)
        h.store.actions=[:];h.store.lastMoodEvent=[:];h.store.feed(1,food:.berry);precondition(h.store.heldItems[1]=="🍓" && h.store.actions[1] == .eat && h.store.expression(1) == .happy)
        let xp=h.store.profile(1).xp;h.store.feed(1,food:.rice);precondition(h.store.profile(1).xp==xp)
        var tired=CareProfile();var f=Feelings();f.energy=1;f.joy=15;tired.feelings=f;h.store.care["2"]=tired;precondition(h.store.expression(2) != .sad)
        h.store.rename("小狼",id:0);h.store.playerName="小羊";let oldBond=h.store.bond(0,1);h.store.befriend(0,1);precondition(h.store.bond(0,1)>oldBond)
        for _ in 0..<5{h.store.lastMoodEvent=[:];h.store.affect(.learn,id:3)};precondition(h.store.style(3).contains("好奇"))
        h.store.actions=[:];h.store.setMood(.sad,id:0);h.comfort(0);precondition(h.social?.kind==4 && h.social?.a==0)
        if let a=h.social?.a,let b=h.social?.b {h.pets[a]?.setFrameOrigin(NSPoint(x:200,y:10));h.pets[b]?.setFrameOrigin(NSPoint(x:224,y:10));h.updateSocial();precondition(h.store.expression(a) == .happy && h.store.expression(b) == .happy)}
        h.endSocial();h.store.actions=[:];h.beginScene(.study);precondition(h.scene?.kind == .study && h.store.activityLocked.count==8 && h.store.pomodoroRunning)
        for id in 0..<8{precondition(h.store.actions[id] == .read && h.store.heldItems[id]=="📖")}
        h.store.studyCompleted={h.finishStudy()}
        let origin=h.stageWindow!.frame;let position=h.pets[0]!.frame
        h.moveStudy(CGSize(width:18,height:-12),ended:true)
        precondition(h.scene?.kind == .study && h.store.pomodoroRunning)
        precondition(abs(h.stageWindow!.frame.minX-origin.minX-18)<1 && abs(h.pets[0]!.frame.minX-position.minX-18)<1)
        h.dragOrigins[0] = .zero;h.store.busy.insert(0);h.updateScene();precondition(h.scene?.kind == .study);h.dragOrigins=[:];h.store.busy=[]
        h.beginScene(.picnic);h.startGame();precondition(h.scene?.kind == .study && h.game==nil)
        h.store.pomodoroRemaining=1;h.store.pomodoroLast=Date().addingTimeInterval(-2);h.store.tickPomodoro();precondition(h.scene==nil && !h.store.pomodoroRunning)
        h.beginScene(.study);h.endScene(manual:true);precondition(h.store.activityLocked.isEmpty && !h.store.pomodoroRunning)
        for kind in Scenario.allCases where kind != .study{
            h.store.actions=[:];h.beginScene(kind);precondition(h.scene != nil && h.store.activityLocked.count==8)
            for phase in 0..<4{h.updateScene();precondition(h.scene?.phase==phase && h.scene?.performed==true);h.scene?.started=Date().addingTimeInterval(-9);h.updateScene()}
            precondition(h.scene==nil && h.store.heldItems.isEmpty && h.store.activityLocked.isEmpty)
        }
        for kind in GameKind.allCases {
            h.store.actions=[:];h.store.gameSettings=GameSettings(kind:kind,rounds:2,seconds:8,title:"测试游戏",customRules:"轮流参加")
            h.startGame();precondition(h.game != nil && h.store.activityLocked.count==8)
            h.updateGame();precondition(h.game?.announced==true)
            if kind == .hide{precondition(h.store.hiddenPets.count==7);h.game?.started=Date().addingTimeInterval(-6);h.updateGame();precondition(h.store.hiddenPets.count<7)}
            if kind == .rps{precondition(h.store.heldItems.values.contains(where:["✊","✋","✌️"].contains))}
            for _ in 0..<2{h.game?.started=Date().addingTimeInterval(-9);h.updateGame();if h.game != nil{h.updateGame()}}
            precondition(h.game==nil && h.store.hiddenPets.isEmpty && h.store.activityLocked.isEmpty)
        }
        precondition(GameRules.result(0,2)==1 && GameRules.result(2,1)==1 && GameRules.result(1,0)==1 && GameRules.result(0,1)==(-1) && GameRules.result(2,2)==0)
        h.store.actions=[:];h.startGame();h.store.enterHouse(0);h.updateGame();precondition(h.game==nil && h.store.housed.contains(0))
        h.store.housed=Set(0..<8);h.store.showAll();h.startGame();precondition(h.game==nil && h.store.activePets.isEmpty)
        h.store.say("应被抑制",id:0);h.store.act(.fly,id:0);precondition(h.store.bubbles[0]==nil && h.store.actions[0] != .fly)
        h.store.persist();let restored=Store();precondition(restored.petName(0)=="小狼" && restored.playerName=="小羊" && restored.housed.count==8 && restored.bond(0,1)>=oldBond)
        let legacy="{\"visible\":[0],\"chats\":{},\"schedules\":[],\"positions\":{}}".data(using:.utf8)!
        precondition((try! JSONDecoder().decode(SavedState.self,from:legacy)).gameSettings==nil)
        precondition(DesktopBounds.petFrame(full:NSRect(x:0,y:0,width:1440,height:900),visible:NSRect(x:0,y:80,width:1440,height:795)).minY == -18)
        print("PASS: brief sadness + recovery, food/hug happiness, fatigue without crying, selected handheld foods, nurture personality, nicknames and player name, bonds, study books/seated lock, study drag/chat persistence and explicit/timed completion, all 6 games for 2 rounds, RPS outcomes, house cancellation/no escape, persistence and old-save compatibility")
        exit(0)
    }
    if let index=CommandLine.arguments.firstIndex(of:"--render-v06"),CommandLine.arguments.count>index+1 {
        let demo=Store();demo.housed=Set(0..<8)
        let view=VStack(alignment:.leading,spacing:14){
            Text("LittleCompanions · 小房间、手持物和小场景").font(.system(size:24,weight:.bold,design:.rounded)).foregroundStyle(.indigo)
            HStack(alignment:.center,spacing:22){PetHouseView(store:demo);VStack(alignment:.leading,spacing:6){Text("每只都有自己的房间").font(.headline);Text("屋顶 LittleCompanions · 房子缩小 · 八种装修\n在家不被打扰，手动才会出来").font(.caption).foregroundStyle(.secondary);HStack{PetArt(character:Character.all[6],action:.special,time:1.2).frame(width:68,height:72);PetArt(character:Character.all[7],action:.special,time:1.2).frame(width:68,height:72);PetArt(character:Character.all[0],action:.fly,time:1.2).frame(width:68,height:72)};Text("摇尾陪伴 / 眯眼问好 / 侧身飞行").font(.caption2)}}
            HStack(spacing:16){activityPreview(kind:Scenario.study.rawValue);activityPreview(kind:Scenario.picnic.rawValue)}
            HStack(spacing:16){activityPreview(kind:GameKind.hop.rawValue);activityPreview(kind:GameKind.karaoke.rawValue)}
            Text("程序内素材和场景预览 · 学习拿书、吃饭拿食物 · 原来的大主页与小气泡保留").font(.caption).foregroundStyle(.secondary)
        }.padding(22).background(Color(red:0.97,green:0.96,blue:0.99))
        let host=NSHostingView(rootView:view.frame(width:728,height:680));let canvas=NSWindow(contentRect:NSRect(x:0,y:0,width:728,height:680),styleMask:.borderless,backing:.buffered,defer:false);canvas.contentView=host;host.frame=NSRect(x:0,y:0,width:728,height:680);host.layoutSubtreeIfNeeded();RunLoop.current.run(until:Date().addingTimeInterval(0.2));host.layoutSubtreeIfNeeded()
        let rep=host.bitmapImageRepForCachingDisplay(in:host.bounds)!;host.cacheDisplay(in:host.bounds,to:rep);try! rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[index+1]));print("v0.6 preview rendered");exit(0)
    }
    if CommandLine.arguments.contains("--social-test") {
        guard ProcessInfo.processInfo.environment["LITTLECOMPANIONS_DATA_DIR"] != nil else{exit(1)}
        let bounds=NSScreen.main?.visibleFrame ?? NSRect(x:0,y:0,width:1440,height:900)
        let harness=AppDelegate();harness.layoutBoundsOverride=bounds;harness.store.visible=[0,1];harness.store.socialEnabled=true
        for id in [0,1]{harness.pets[id]=PetPanel(contentRect:NSRect(x:bounds.minX+100+Double(id)*100,y:bounds.minY+70,width:74,height:84),styleMask:.borderless,backing:.buffered,defer:false)}
        for kind in 0..<8 {
            harness.store.actions=[:];harness.startSocial(preferred:0,force:true);precondition(harness.social != nil)
            harness.social=SocialSession(a:0,b:1,kind:kind,started:Date())
            harness.pets[0]?.setFrameOrigin(NSPoint(x:bounds.minX+100,y:bounds.minY+70));harness.pets[1]?.setFrameOrigin(NSPoint(x:bounds.minX+(kind==6 ? 215:124),y:bounds.minY+70));harness.updateSocial()
            precondition(harness.social?.phase==1 && harness.store.socialMarks.count==2 && harness.store.bubbles[0] != nil)
            harness.social?.started=Date().addingTimeInterval(-1.2);harness.updateSocial()
            precondition(harness.social?.replied==true && harness.store.bubbles[1] != nil)
            if kind==3{precondition(harness.socialTargets.count==2)}
            harness.social?.started=Date().addingTimeInterval(kind==6 ? -11:-7);harness.updateSocial()
            precondition(harness.social==nil && harness.store.socialMarks.isEmpty)
        }
        harness.store.actions=[:];harness.startSocial(preferred:0,force:true);harness.store.act(.sleep,id:1);harness.updateSocial()
        precondition(harness.social==nil && harness.store.actions[1] == .sleep)
        harness.store.actions=[:];harness.store.busy=[1];harness.startSocial(preferred:0,force:true);precondition(harness.social==nil)
        print("PASS: 8 social interactions including close hug, high five, ball play and dance; replies, cleanup, sleep/chat protection")
        exit(0)
    }
    if let index=CommandLine.arguments.firstIndex(of:"--render-social-gif"),CommandLine.arguments.count>index+1 {
        let url=URL(fileURLWithPath:CommandLine.arguments[index+1])
        let destination=CGImageDestinationCreateWithURL(url as CFURL,"com.compuserve.gif" as CFString,60,nil)!
        CGImageDestinationSetProperties(destination,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        for frame in 0..<60 {
            let t=Double(frame)/10
            let progress=t<1.6 ? t/1.6:t>4.6 ? max(0,(6-t)/1.4):1
            let walking=t<1.6 || t>4.6
            let action:Action=walking ? .walk:t<3.1 ? .wave:.jump
            let scene=VStack(spacing:6){
                Text("小伙伴一起玩").font(.system(size:22,weight:.bold,design:.rounded)).foregroundStyle(Color(red:0.43,green:0.34,blue:0.65))
                ZStack(alignment:.topLeading){
                    if !walking {
                        Text(t<3.1 ? "嗨，小伙伴 2！":"一起跳一下？").font(.system(size:13,weight:.medium)).padding(9).background(.white,in:Capsule()).position(x:205,y:30)
                        Text(t<3.1 ? "来啦～":"一、二、三！").font(.system(size:13,weight:.medium)).padding(9).background(.white,in:Capsule()).position(x:435,y:30)
                    }
                    PetArt(character:Character.all[0],action:action,time:t+1.7).frame(width:136,height:158).position(x:135+progress*70,y:145)
                    PetArt(character:Character.all[1],action:action,time:t+1.9).frame(width:136,height:158).scaleEffect(x:walking ? -1:1,y:1).position(x:505-progress*70,y:145)
                }.frame(width:640,height:245)
                Text("程序内动画素材示意 · 实际互动需至少显示两只醒着的小伙伴").font(.system(size:10)).foregroundStyle(.secondary)
            }.padding(18).background(Color(red:0.97,green:0.95,blue:0.98))
            let renderer=ImageRenderer(content:scene);renderer.scale=1
            guard let cg=renderer.cgImage else{exit(1)}
            CGImageDestinationAddImage(destination,cg,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.1]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(destination));print("Interaction GIF rendered");exit(0)
    }
    if let index=CommandLine.arguments.firstIndex(of:"--render-expressions"),CommandLine.arguments.count>index+1 {
        let sheet=VStack(spacing:8){
            Text("LittleCompanions · 八只小表情").font(.system(size:26,weight:.bold,design:.rounded)).foregroundStyle(Color(red:0.43,green:0.34,blue:0.65)).padding(.bottom,10)
            HStack{Color.clear.frame(width:100,height:20);ForEach(PetExpression.allCases){mood in Text(mood.rawValue).font(.headline).frame(width:106)}}
            ForEach(Character.all){pet in
                HStack{Text(pet.name).font(.system(size:12,weight:.semibold)).frame(width:100);ForEach(PetExpression.allCases){mood in PetArt(character:pet,time:1.7,expression:mood).frame(width:106,height:120)}}.padding(.vertical,5).background(.white,in:RoundedRectangle(cornerRadius:13))
            }
        }.padding(20).background(Color(red:0.97,green:0.95,blue:0.98))
        let renderer=ImageRenderer(content:sheet);renderer.scale=2
        if let image=renderer.nsImage,let tiff=image.tiffRepresentation,let rep=NSBitmapImageRep(data:tiff),let data=rep.representation(using:.png,properties:[:]){try! data.write(to:URL(fileURLWithPath:CommandLine.arguments[index+1]));print("Expression preview rendered")}else{exit(1)}
        exit(0)
    }
    if let index=CommandLine.arguments.firstIndex(of:"--render-lookbook"),CommandLine.arguments.count>index+1 {
        let outfits:[Outfit]=[.picnic,.whiteSet,.bib,.pinkSet,.picnic,.whiteSet,.pinkSet,.bib]
        let accessories:[Accessory]=[.bucket,.flowers,.visor,.bow,.flowers,.bow,.glasses,.bucket]
        let moods:[PetExpression]=[.happy,.neutral,.angry,.excited,.excited,.happy,.sad,.neutral]
        let sheet=VStack(spacing:18){
            Text("LittleCompanions · 表情与小衣橱").font(.system(size:28,weight:.bold,design:.rounded)).foregroundStyle(Color(red:0.43,green:0.34,blue:0.65))
            Text("按你提供的豆豆眼图片生成 · 服装、饰品可独立搭配").font(.callout).foregroundStyle(.secondary)
            LazyVGrid(columns:Array(repeating:GridItem(.fixed(190)),count:4),spacing:14){
                ForEach(Character.all){pet in
                    VStack(spacing:8){
                        PetArt(character:pet,time:1.7,outfit:outfits[pet.id],expression:moods[pet.id],accessory:accessories[pet.id]).frame(width:165,height:180)
                        Text(pet.name).font(.headline)
                        Text("\(moods[pet.id].rawValue) · \(outfits[pet.id].rawValue)").font(.caption).foregroundStyle(.secondary)
                    }.frame(width:185,height:236).background(.white,in:RoundedRectangle(cornerRadius:18))
                }
            }
            Text("这是搭配预览；实际养成从不穿衣服、不戴饰品开始。").font(.caption).foregroundStyle(.secondary)
        }.padding(24).background(Color(red:0.97,green:0.95,blue:0.98))
        let renderer=ImageRenderer(content:sheet);renderer.scale=2
        if let image=renderer.nsImage,let tiff=image.tiffRepresentation,let rep=NSBitmapImageRep(data:tiff),let data=rep.representation(using:.png,properties:[:]){try! data.write(to:URL(fileURLWithPath:CommandLine.arguments[index+1]));print("Lookbook rendered")}else{exit(1)}
        exit(0)
    }
    if let index=CommandLine.arguments.firstIndex(of:"--render-v05"),CommandLine.arguments.count>index+1 {
        let demo=Store();demo.housed=Set(0..<8);demo.chats=["0":[Message(role:"user",text:"今天一起去野餐吧！"),Message(role:"assistant",text:"好呀，我带上小篮子。等大家出来，我们一起出发～")]]
        let view=VStack(alignment:.leading,spacing:16){
            Text("小小陪伴站 · 安静屋与一起玩").font(.system(size:25,weight:.bold,design:.rounded)).foregroundStyle(.indigo)
            HStack(alignment:.top,spacing:30){
                VStack(alignment:.leading){Text("可选迷你聊天 · 320 × 300").font(.headline);CompactChat(store:demo).frame(width:320,height:300).clipShape(RoundedRectangle(cornerRadius:14))}
                VStack(alignment:.leading,spacing:10){Text("拖进房子，开启安静休息").font(.headline);PetHouseView(store:demo);Text("不自行出门 · 不弹气泡 · 点一下才出来").font(.caption).foregroundStyle(.secondary)}
            }
            Divider()
            HStack(spacing:20){
                VStack(spacing:5){HStack(spacing:-25){PetArt(character:Character.all[0],action:.hug,time:1.7,expression:.happy).frame(width:100,height:105).rotationEffect(.degrees(12),anchor:.bottom);PetArt(character:Character.all[1],action:.hug,time:1.7,expression:.happy).frame(width:100,height:105).scaleEffect(x:-1,y:1).rotationEffect(.degrees(-12),anchor:.bottom)};Text("靠近抱抱 · 心情变好").font(.caption)}
                VStack(alignment:.leading,spacing:8){ForEach(Scenario.allCases){scene in Text(scene.icon+" "+scene.rawValue+" · "+scene.lines[1]).font(.system(size:12))}}
            }
            Text("界面与动作素材示意；每只的心情会随陪伴、学习、穿衣、喂食和伙伴互动变化。").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width:760,height:590).background(Color(red:0.97,green:0.96,blue:0.99))
        let host=NSHostingView(rootView:view);let canvas=NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:590),styleMask:.borderless,backing:.buffered,defer:false)
        canvas.contentView=host;host.frame=NSRect(x:0,y:0,width:760,height:590);host.layoutSubtreeIfNeeded();RunLoop.current.run(until:Date().addingTimeInterval(0.3));host.layoutSubtreeIfNeeded()
        guard let rep=host.bitmapImageRepForCachingDisplay(in:host.bounds) else{exit(1)}
        host.cacheDisplay(in:host.bounds,to:rep);guard let data=rep.representation(using:.png,properties:[:]) else{exit(1)}
        try! data.write(to:URL(fileURLWithPath:CommandLine.arguments[index+1]));print("v0.5 preview rendered");exit(0)
    }
    if let index=CommandLine.arguments.firstIndex(of:"--render-care") ?? CommandLine.arguments.firstIndex(of:"--render-activity"),CommandLine.arguments.count>index+1 {
        let previewStore=Store();previewStore.selected=0;previewStore.requestedTab=CommandLine.arguments.contains("--render-activity") ? 5:2;previewStore.care=[:]
        let host=NSHostingView(rootView:MainView(store:previewStore,tab:CommandLine.arguments.contains("--render-activity") ? 5:2).frame(width:960,height:720))
        let canvas=NSWindow(contentRect:NSRect(x:0,y:0,width:960,height:720),styleMask:.borderless,backing:.buffered,defer:false)
        canvas.contentView=host;host.frame=NSRect(x:0,y:0,width:960,height:720)
        host.layoutSubtreeIfNeeded();RunLoop.current.run(until:Date().addingTimeInterval(0.3));host.layoutSubtreeIfNeeded()
        if let rep=host.bitmapImageRepForCachingDisplay(in:host.bounds){
            host.cacheDisplay(in:host.bounds,to:rep)
            if let data=rep.representation(using:.png,properties:[:]){try! data.write(to:URL(fileURLWithPath:CommandLine.arguments[index+1]));print("Care preview rendered")}
        }else{exit(1)}
        exit(0)
    }
    if let index=CommandLine.arguments.firstIndex(of:"--render-preview"),CommandLine.arguments.count>index+1 {
        let sheet=VStack(spacing:20){
            Text("LittleCompanions · 小小陪伴站").font(.system(size:30,weight:.bold,design:.rounded)).foregroundStyle(Color(red:0.43,green:0.34,blue:0.65))
            Text("豆豆眼 · 按你提供的图片生成 · 放大形象预览").foregroundStyle(.secondary)
            LazyVGrid(columns:Array(repeating:GridItem(.fixed(200)),count:4),spacing:18){
                ForEach(Character.all){pet in
                    VStack(spacing:4){PetArt(character:pet,time:1.7).frame(width:145,height:160);Text(pet.name).font(.headline);Text(pet.special).font(.caption).foregroundStyle(.secondary)}.frame(width:190,height:215).background(.white,in:RoundedRectangle(cornerRadius:20))
                }
            }
            Text("实际桌宠默认高约 59 点，约为初版面积的 1/10；此图放大展示细节").font(.caption).foregroundStyle(.secondary)
        }.padding(30).background(Color(red:0.97,green:0.95,blue:0.98))
        let renderer=ImageRenderer(content:sheet);renderer.scale=2
        if let image=renderer.nsImage,let tiff=image.tiffRepresentation,let rep=NSBitmapImageRep(data:tiff),let data=rep.representation(using:.png,properties:[:]) {
            try! data.write(to:URL(fileURLWithPath:CommandLine.arguments[index+1]));print("Preview rendered")
        }else{print("Preview render failed");exit(1)}
        exit(0)
    }
    let delegate=AppDelegate()
    app.delegate=delegate
    withExtendedLifetime(delegate){app.run()}
}
