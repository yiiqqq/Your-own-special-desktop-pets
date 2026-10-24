import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PetDesign:Codable {
    var version=1
    var shape="bean"
    var color="#a8cdbb"
    var accent="#efd69c"
    var ears="none"
    var eyes="dot"
    var tail=true
    var persona="温柔好奇，喜欢和伙伴一起探索"
    var images:[String:String]=[:]
    static let slots=["neutral","happy","angry","sad","excited","side","back"]
    func normalized()->PetDesign {
        var d=PetDesign()
        if ["orb","bean","droplet"].contains(shape){d.shape=shape}
        if ["none","round","leaf"].contains(ears){d.ears=ears}
        if ["dot","spark"].contains(eyes){d.eyes=eyes}
        if color.range(of:"^#[0-9a-fA-F]{6}$",options:.regularExpression) != nil{d.color=color}
        if accent.range(of:"^#[0-9a-fA-F]{6}$",options:.regularExpression) != nil{d.accent=accent}
        d.tail=tail;d.persona=String(persona.prefix(200))
        for slot in Self.slots{if let value=images[slot],Self.png(value) != nil{d.images[slot]=value}}
        return d
    }
    static func png(_ value:String)->Data? {
        let prefix="data:image/png;base64,"
        guard value.hasPrefix(prefix),value.utf8.count<=1_500_000,let data=Data(base64Encoded:String(value.dropFirst(prefix.count))),data.count>=33,data.count<=1_048_576 else{return nil}
        let b=[UInt8](data);guard Array(b.prefix(8))==[137,80,78,71,13,10,26,10],String(bytes:b[12..<16],encoding:.ascii)=="IHDR" else{return nil}
        func size(_ n:Int)->Int{(n..<(n+4)).reduce(0){($0<<8)|Int(b[$1])}}
        guard (1...2048).contains(size(16)),(1...2048).contains(size(20)),NSBitmapImageRep(data:data) != nil else{return nil};return data
    }
    static func nsColor(_ hex:String)->NSColor{let n=Int(hex.dropFirst(),radix:16) ?? 0xa8cdbb;return NSColor(srgbRed:Double((n>>16)&255)/255,green:Double((n>>8)&255)/255,blue:Double(n&255)/255,alpha:1)}
    static func hex(_ color:Color)->String{let c=NSColor(color).usingColorSpace(.sRGB) ?? .white;return String(format:"#%02x%02x%02x",Int((c.redComponent*255).rounded()),Int((c.greenComponent*255).rounded()),Int((c.blueComponent*255).rounded()))}
}
struct CharacterFile:Codable{var format="little-companions-character";var version=1;var name:String;var design:PetDesign}
final class DesignLibrary:ObservableObject {
    static let shared=DesignLibrary()
    @Published var designs:[String:PetDesign]=[:]
    @Published var status=""
    private var cache:[String:NSImage]=[:]
    var file:URL {let root=ProcessInfo.processInfo.environment["LITTLECOMPANIONS_DATA_DIR"].map{URL(fileURLWithPath:$0)} ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("LittleCompanions");return root.appendingPathComponent("designs.json")}
    init(){if let data=try? Data(contentsOf:file),data.count<=80*1024*1024,let v=try? JSONDecoder().decode([String:PetDesign].self,from:data){for i in 0..<8{if let d=v[String(i)]{designs[String(i)]=d.normalized()}}}}
    func design(_ id:Int)->PetDesign{designs[String(id)] ?? PetDesign()}
    func save(_ d:PetDesign,id:Int){designs[String(id)]=d.normalized();cache.removeAll();do{try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true);try JSONEncoder().encode(designs).write(to:file,options:.atomic);status="角色已保存，桌面和小房间会同步变化"}catch{status="保存失败：\(error.localizedDescription)"}}
    func image(_ value:String)->NSImage?{if let image=cache[value]{return image};guard let data=PetDesign.png(value),let image=NSImage(data:data) else{return nil};if cache.count>64{cache.removeAll()};cache[value]=image;return image}
    func importPNG(id:Int,slot:String){let panel=NSOpenPanel();panel.allowedContentTypes=[.png];guard panel.runModal() == .OK,let url=panel.url else{return};do{let attrs=try FileManager.default.attributesOfItem(atPath:url.path);guard (attrs[.size] as? Int ?? Int.max)<=1_048_576 else{status="图片超过 1 MB，请先缩小";return};let data=try Data(contentsOf:url);let value="data:image/png;base64,"+data.base64EncodedString();guard PetDesign.png(value) != nil,let image=NSImage(data:data) else{status="请选择不超过 1 MB / 2048 × 2048 的 PNG";return};let ratio=min(1,512/max(image.size.width,image.size.height));let target=NSImage(size:NSSize(width:image.size.width*ratio,height:image.size.height*ratio));target.lockFocus();image.draw(in:NSRect(origin:.zero,size:target.size));target.unlockFocus();guard let tiff=target.tiffRepresentation,let rep=NSBitmapImageRep(data:tiff),let png=rep.representation(using:.png,properties:[:]) else{return};var d=design(id);d.images[slot]="data:image/png;base64,"+png.base64EncodedString();save(d,id:id)}catch{status=error.localizedDescription}}
    func exportFile(id:Int,name:String){let panel=NSSavePanel();panel.allowedContentTypes=[.json];panel.nameFieldStringValue="my-character.littlepet.json";guard panel.runModal() == .OK,let url=panel.url else{return};do{let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];try encoder.encode(CharacterFile(name:name,design:design(id))).write(to:url,options:.atomic);status="角色已导出，不含聊天和密钥"}catch{status=error.localizedDescription}}
    func importFile(id:Int)->String?{let panel=NSOpenPanel();panel.allowedContentTypes=[.json];guard panel.runModal() == .OK,let url=panel.url else{return nil};do{let attrs=try FileManager.default.attributesOfItem(atPath:url.path);guard (attrs[.size] as? Int ?? Int.max)<=10*1024*1024 else{status="角色文件超过 10 MB";return nil};let value=try JSONDecoder().decode(CharacterFile.self,from:Data(contentsOf:url));guard value.format=="little-companions-character",value.version==1 else{status="不是支持的角色文件";return nil};save(value.design,id:id);return String(value.name.prefix(24))}catch{status="导入失败：\(error.localizedDescription)";return nil}}
}
struct CreatorPanel:View {
    @ObservedObject var store:Store
    @ObservedObject var library=DesignLibrary.shared
    @State var slot="neutral"
    func text(_ key:WritableKeyPath<PetDesign,String>)->Binding<String>{Binding(get:{library.design(store.selected)[keyPath:key]},set:{v in var d=library.design(store.selected);d[keyPath:key]=v;library.save(d,id:store.selected)})}
    func color(_ key:WritableKeyPath<PetDesign,String>)->Binding<Color>{Binding(get:{Color(nsColor:PetDesign.nsColor(library.design(store.selected)[keyPath:key]))},set:{v in var d=library.design(store.selected);d[keyPath:key]=PetDesign.hex(v);library.save(d,id:store.selected)})}
    var body:some View {
        ScrollView{VStack(alignment:.leading,spacing:14){
            Text("创造自己的小伙伴").font(.title2.bold())
            Text("可以修改基础造型，也可以导入自己的透明 PNG。完整立绘整体运动；程序化造型有活动四肢。").font(.caption).foregroundStyle(.secondary)
            PetArt(character:Character.all[store.selected],action:.wave,time:1).frame(width:160,height:170)
            HStack{Picker("身体",selection:text(\.shape)){Text("圆团").tag("orb");Text("豆豆").tag("bean");Text("水滴").tag("droplet")};Picker("头顶",selection:text(\.ears)){Text("圆润").tag("none");Text("圆耳").tag("round");Text("叶芽").tag("leaf")};Picker("眼睛",selection:text(\.eyes)){Text("豆豆眼").tag("dot");Text("亮晶晶").tag("spark")}}
            HStack{ColorPicker("身体颜色",selection:color(\.color),supportsOpacity:false);ColorPicker("点缀颜色",selection:color(\.accent),supportsOpacity:false)}
            Toggle("小尾巴",isOn:Binding(get:{library.design(store.selected).tail},set:{v in var d=library.design(store.selected);d.tail=v;library.save(d,id:store.selected)}))
            TextField("性格（最多 200 字）",text:text(\.persona)).textFieldStyle(.roundedBorder)
            HStack{Picker("图片格",selection:$slot){ForEach(Array(zip(PetDesign.slots,["普通","开心","生气","委屈","惊喜","侧面","背面"])),id:\.0){k,v in Text(v).tag(k)}};Button("导入 PNG"){library.importPNG(id:store.selected,slot:slot)};Button("清除此格"){var d=library.design(store.selected);d.images.removeValue(forKey:slot);library.save(d,id:store.selected)}}
            Text("已导入："+library.design(store.selected).images.keys.sorted().joined(separator:"、")).font(.caption)
            HStack{Button("导出角色文件"){library.exportFile(id:store.selected,name:store.petName(store.selected))};Button("导入角色文件"){if let name=library.importFile(id:store.selected){var p=store.profile(store.selected);p.nickname=name;store.care[String(store.selected)]=p;store.persist()}};Button("重置外观"){library.save(PetDesign(),id:store.selected)}}
            Text("修改自动保存在本机。角色文件只包含名字、外观、图片和性格，不包含聊天、日程或密钥。请只导入有权使用的素材。缺少侧背面时使用程序化造型。").font(.caption).foregroundStyle(.secondary)
            Text(library.status).font(.caption)
        }.padding(4)}
    }
}
struct CustomPetView:View {
    let id:Int
    let action:Action
    let time:Double
    let expression:PetExpression
    let outfit:Outfit
    let accessory:Accessory
    let held:String?
    let direction:String
    @ObservedObject var library=DesignLibrary.shared
    var body:some View {
        Canvas{context,size in
            let d=library.design(id),side=direction=="side" || [.walk,.fly].contains(action),back=direction=="back" || action == .back
            let mood=[Action.eat,.hug,.wave,.dance,.special].contains(action) ? "happy":[Action.read,.sleep,.sit].contains(action) ? "neutral":expression.assetKey
            let slot=back ? "back":side ? "side":mood
            var c=context;c.scaleBy(x:size.width/100,y:size.height/100);c.translateBy(x:50,y:54)
            let fill=Color(nsColor:PetDesign.nsColor(d.color)),accent=Color(nsColor:PetDesign.nsColor(d.accent)),ink=Color(red:0.32,green:0.39,blue:0.42)
            func ellipse(_ x:Double,_ y:Double,_ w:Double,_ h:Double,_ color:Color,_ ctx:GraphicsContext){let p=Path(ellipseIn:CGRect(x:x-w,y:y-h,width:w*2,height:h*2));ctx.fill(p,with:.color(color));ctx.stroke(p,with:.color(ink),lineWidth:1.5)}
            let source=d.images[slot] ?? (!side && !back ? d.images["neutral"]:nil)
            if let source,let image=library.image(source){let ratio=min(80/image.size.width,80/image.size.height);let w=image.size.width*ratio,h=image.size.height*ratio;c.draw(Image(nsImage:image),in:CGRect(x:-w/2,y:-12-h/2,width:w,height:h))}
            else {
                if d.tail{var tail=c;tail.translateBy(x:18,y:15);tail.rotate(by:.degrees(action == .special ? sin(time*12)*35:-20));ellipse(9,0,14,5,accent,tail)}
                for sign in [-1.0,1.0]{var leg=c;leg.translateBy(x:sign*12,y:23);leg.rotate(by:.degrees(action == .kick && sign>0 ? -max(0,sin(time*20))*50:action == .walk ? sin(time*8+sign)*20:0));ellipse(0,0,8,5,fill,leg)}
                for sign in [-1.0,1.0]{var arm=c;arm.translateBy(x:sign*20,y:7);let lift=[Action.wave,.dance,.special,.jump].contains(action);arm.rotate(by:.degrees(sign*(lift ? -55+sin(time*8)*17:[Action.read,.eat,.hug].contains(action) ? 45:12)));ellipse(sign*5,0,10,5,fill,arm)}
                if d.ears=="round"{ellipse(-15,-28,8,9,fill,c);ellipse(15,-28,8,9,fill,c)}
                if d.ears=="leaf"{var p=Path();p.move(to:CGPoint(x:0,y:-29));p.addQuadCurve(to:CGPoint(x:0,y:-45),control:CGPoint(x:-16,y:-51));p.addQuadCurve(to:CGPoint(x:0,y:-29),control:CGPoint(x:17,y:-48));c.fill(p,with:.color(accent));c.stroke(p,with:.color(ink),lineWidth:1.5)}
                if d.shape=="droplet"{var p=Path();p.move(to:CGPoint(x:0,y:-36));p.addCurve(to:CGPoint(x:0,y:26),control1:CGPoint(x:30,y:-7),control2:CGPoint(x:30,y:24));p.addCurve(to:CGPoint(x:0,y:-36),control1:CGPoint(x:-30,y:24),control2:CGPoint(x:-30,y:-7));c.fill(p,with:.color(fill));c.stroke(p,with:.color(ink),lineWidth:1.5)}else{ellipse(0,-2,d.shape=="orb" ? 25:23,d.shape=="orb" ? 25:30,fill,c)}
                if outfit != .none{let cloth=Path(roundedRect:CGRect(x:-16,y:9,width:32,height:12),cornerRadius:5);c.fill(cloth,with:.color(outfit == .picnic ? .blue.opacity(0.5):outfit == .pinkSet ? .pink.opacity(0.4):accent));c.stroke(cloth,with:.color(ink),lineWidth:1)}
                if back{ellipse(0,10,4,4,accent,c)}else{
                    for x in side ? [-12.0]:[-9.0,9.0]{
                        if ["happy","angry","sad"].contains(mood) || action == .sleep {var p=Path();p.move(to:CGPoint(x:x-3,y:-8));p.addQuadCurve(to:CGPoint(x:x+3,y:-8),control:CGPoint(x:x,y:mood=="sad" ? -6:-13));c.stroke(p,with:.color(ink),style:StrokeStyle(lineWidth:1.5,lineCap:.round))}
                        else{ellipse(x,-9,2.7,d.eyes=="spark" ? 4:3,ink,c);if d.eyes=="spark"{c.fill(Path(ellipseIn:CGRect(x:x-1.6,y:-11,width:2,height:2)),with:.color(.white))}}
                    }
                    var mouth=Path();mouth.move(to:CGPoint(x:-4,y:1));mouth.addQuadCurve(to:CGPoint(x:4,y:1),control:CGPoint(x:0,y:mood=="sad" ? -3:6));c.stroke(mouth,with:.color(ink),style:StrokeStyle(lineWidth:1.5,lineCap:.round));for x in [-15.0,15.0]{c.fill(Path(ellipseIn:CGRect(x:x-4,y:-3,width:8,height:4)),with:.color(accent))}
                }
                if accessory != .none{let mark=accessory == .bow ? "🎀":accessory == .flowers ? "🌼":accessory == .glasses ? "👓":"👒";c.draw(Text(mark).font(.system(size:17)),at:CGPoint(x:0,y:accessory == .glasses ? -9:-30))}
            }
            if let item=held ?? (action == .read ? "📖":action == .eat ? "🍎":nil){c.draw(Text(item).font(.system(size:19)),at:CGPoint(x:0,y:11));ellipse(-9,11,4,3,fill,c);ellipse(9,11,4,3,fill,c)}
            if action == .sleep{c.draw(Text("z Z").font(.system(size:11)).foregroundStyle(ink),at:CGPoint(x:28,y:-30))}
        }
    }
}
