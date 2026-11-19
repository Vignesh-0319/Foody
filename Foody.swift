import SwiftUI
import Charts
import Security

private typealias Local<T> = SwiftUI.State<T>
let spice = Color(red:0.72,green:0.25,blue:0.04)
let verdicts = ["Must try","Go for it","Skip it"]
struct Ballot: Codable { let verdict:String; let paid:Int; let filling:Bool }
struct Comment: Decodable, Identifiable { let id:Int; let author,body:String }
struct Meal: Decodable, Identifiable {
    let id,uni,name,restaurant,icon:String
    let low,high,minutes,full:Int
    let counts:[Int]
    let mine:Ballot?
    let comments:[Comment]
    var total:Int { counts.reduce(0,+) }
}
struct Profile: Decodable { let name:String; let uni:String?; let budget:Int }
struct Snapshot: Decodable { let universities:[String]; let meals:[Meal]; let profile:Profile }
struct Failure: LocalizedError { let message:String; var errorDescription:String? { message } }

enum Identity {
    static func token() throws -> String {
        let item:[String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"Foody device account",kSecAttrAccount as String:"identity"]
        var query=item; query[kSecReturnData as String]=true
        var result:CFTypeRef?
        let status=SecItemCopyMatching(query as CFDictionary,&result)
        if status==errSecSuccess,let bytes=result as? Data,let stored=String(data:bytes,encoding:.utf8){return stored}
        guard status==errSecItemNotFound else {throw Failure(message:"Unlock this device to access your profile.")}
        var random=[UInt8](repeating:0,count:32)
        guard SecRandomCopyBytes(kSecRandomDefault,32,&random)==errSecSuccess else {throw Failure(message:"Could not create a device profile.")}
        let token=random.map{String(format:"%02x",$0)}.joined()
        var new=item;new[kSecValueData as String]=Data(token.utf8);new[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(new as CFDictionary,nil)==errSecSuccess else {throw Failure(message:"Could not save the device profile.")}
        return token
    }
}
@MainActor final class Store: ObservableObject {
    @Published var state:Snapshot?
    @Published var busy=false
    @Published var error:String?
    var personalMeals:[Meal] { state?.meals.filter{$0.uni==state?.profile.uni} ?? [] }
    @discardableResult func request(_ path:String="/state",_ body:[String:Any]?=nil) async ->Bool {
        guard !busy else {return false}
        busy=true;defer{busy=false}
        do {
            let base=ProcessInfo.processInfo.environment["FOODY_API_URL"] ?? "http://127.0.0.1:8787"
            guard let url=URL(string:base+path) else {throw Failure(message:"Invalid server address.")}
            var req=URLRequest(url:url);req.timeoutInterval=8
            req.setValue("Bearer "+(try Identity.token()),forHTTPHeaderField:"Authorization")
            if let body {req.httpMethod="POST";req.httpBody=try JSONSerialization.data(withJSONObject:body);req.setValue("application/json",forHTTPHeaderField:"Content-Type")}
            let (data,response)=try await URLSession.shared.data(for:req)
            guard (response as? HTTPURLResponse)?.statusCode==200 else {
                let info=try? JSONDecoder().decode([String:String].self,from:data)
                throw Failure(message:info?["error"] ?? "Server unavailable.")
            }
            state=try JSONDecoder().decode(Snapshot.self,from:data);error=nil;return true
        }catch {self.error=error.localizedDescription;return false}
    }
}
@main struct FoodyApp: App {
    @StateObject private var store=Store()
    var body: some Scene {WindowGroup{Root().environmentObject(store).tint(spice)}}
}
struct Root: View {
    @EnvironmentObject var store:Store
    var body:some View {
        Group {
            if let s=store.state {
                if s.profile.uni==nil {NavigationStack{Universities()}}
                else {TabView{
                    NavigationStack{Explore()}.tabItem{Label("Explore",systemImage:"fork.knife")}
                    NavigationStack{Community()}.tabItem{Label("Community",systemImage:"bubble.left.and.bubble.right")}
                    NavigationStack{Account()}.tabItem{Label("Profile",systemImage:"person.crop.circle")}
                }}
            }else if store.busy {ProgressView("Opening Foody…")}
            else {ContentUnavailableView{Label("Connect to Foody",systemImage:"antenna.radiowaves.left.and.right")} description:{Text("Start the Foody server on your Mac, then reconnect.")}actions:{Button("Reconnect"){Task{await store.request()}}}}
        }.task{if store.state==nil{await store.request()}}
        .alert("Foody couldn’t finish that",isPresented:Binding(get:{store.error != nil},set:{if !$0{store.error=nil}})){Button("OK"){store.error=nil}}message:{Text(store.error ?? "")}
    }
}
struct Universities:View {
    @EnvironmentObject var store:Store
    @Environment(\.dismiss) var dismiss
    @Local private var query=""
    var body:some View {
        let choices=(store.state?.universities ?? []).filter{query.isEmpty || $0.localizedCaseInsensitiveContains(query)}
        List{
            Section("Find meals near your university"){ForEach(choices,id:\.self){u in
                Button{Task{if await store.request("/profile",["uni":u]){dismiss()}}}label:{
                    HStack{Label(u,systemImage:"building.columns");Spacer();if store.state?.profile.uni==u{Image(systemName:"checkmark")}}
                }
            }}
            if choices.isEmpty{Text("No university matches your search.")}
        }.disabled(store.busy).searchable(text:$query,prompt:"Search universities").navigationTitle("Your university")
    }
}
struct BudgetControl:View {
    @EnvironmentObject var store:Store
    var body:some View {
        let budget=store.state?.profile.budget ?? 200
        VStack(alignment:.leading,spacing:8){
            Label("Lunch budget per person",systemImage:"fork.knife").font(.headline)
            Stepper(value:Binding(get:{budget},set:{value in Task{await store.request("/profile",["budget":value])}}),in:100...250,step:50){
                Text("₹\(budget)").font(.system(size:46,weight:.bold,design:.rounded)).monospacedDigit()
            }.disabled(store.busy)
        }.padding(20).foregroundStyle(.black).background(Color(red:1,green:0.83,blue:0.65),in:RoundedRectangle(cornerRadius:24))
    }
}
struct Explore:View {
    @EnvironmentObject var store:Store
    var body:some View {
        let choices=store.personalMeals.filter{$0.high <= (store.state?.profile.budget ?? 200)}
        List{
            NavigationLink{Universities()}label:{Label(store.state?.profile.uni ?? "Choose university",systemImage:"location.fill")}
            BudgetControl().listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            Section("Meals in budget"){ForEach(choices){m in NavigationLink{Dish(id:m.id)}label:{MealLabel(meal:m)}}
                if choices.isEmpty{Text("Raise your budget to see more meals.").foregroundStyle(.secondary)}}
            Text("Demo restaurant listings and starting votes. New votes and comments are shared through your Foody server.").font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("Foody").refreshable{await store.request()}
    }
}
struct MealLabel:View{
    let meal:Meal
    var body:some View{HStack(spacing:12){Text(meal.icon).font(.largeTitle).accessibilityHidden(true);VStack(alignment:.leading,spacing:4){Text(meal.name).font(.headline);Text("\(meal.restaurant) · \(meal.minutes) min walk").font(.caption).foregroundStyle(.secondary);Text("₹\(meal.low)–\(meal.high)").font(.subheadline.bold()).foregroundStyle(spice)}}.padding(.vertical,4)}
}
struct Dish:View{
    let id:String
    @EnvironmentObject var store:Store
    @Local private var expanded=false
    @Local private var voting=false
    var body:some View{
        if let m=store.state?.meals.first(where:{$0.id==id}){
            List{
                Section{MealLabel(meal:m);Text("Reported spend per person, including tax.").font(.footnote)}
                Section("Student verdicts"){
                    Button{withAnimation(.spring(duration:0.4)){expanded.toggle()}}label:{
                        VStack{Chart(Array(verdicts.indices),id:\.self){i in
                            SectorMark(angle:.value("Votes",m.counts[i]),innerRadius:.ratio(0.52),angularInset:expanded ? 4:1).foregroundStyle([spice,Color.green,Color.yellow][i])
                        }.frame(height:expanded ? 206:128).chartBackground{_ in Text("\(m.total)").font(.title.bold())}
                        Text(expanded ? "Collapse breakdown":"Expand breakdown").font(.caption.bold())}
                    }
                    ForEach(verdicts.indices,id:\.self){i in LabeledContent(verdicts[i],value:expanded ? "\(m.counts[i]) of \(m.total)":"\(m.counts[i])")}
                    Label("\(m.full) of \(m.total) found it filling",systemImage:"fork.knife")
                }
                Button(m.mine==nil ? "Vote on this dish":"Edit your vote"){voting=true}
                NavigationLink{Discussion(id:id)}label:{Label("Discussion (\(m.comments.count))",systemImage:"bubble.left.and.bubble.right")}
            }.navigationTitle(m.name).navigationBarTitleDisplayMode(.inline).sheet(isPresented:$voting){VoteForm(m)}
        }
    }
}
struct VoteForm:View{
    let meal:Meal
    @EnvironmentObject var store:Store
    @Environment(\.dismiss) var dismiss
    @Local private var choice:String?
    @Local private var paid:String
    @Local private var full:Bool?
    init(_ meal:Meal){self.meal=meal;_choice=Local(initialValue:meal.mine?.verdict);_paid=Local(initialValue:meal.mine.map{String($0.paid)} ?? "");_full=Local(initialValue:meal.mine?.filling)}
    var body:some View{NavigationStack{Form{
        Section(meal.name){TextField("Amount you paid (₹)",text:$paid).keyboardType(.numberPad)}
        Section("Was it filling?"){Picker("Portion",selection:$full){Text("Choose").tag(nil as Bool?);Text("Yes").tag(true as Bool?);Text("No").tag(false as Bool?)}.pickerStyle(.segmented)}
        Section("Your verdict"){ForEach(verdicts,id:\.self){v in Button{choice=v}label:{HStack{Text(v);Spacer();if choice==v{Image(systemName:"checkmark")}}}}}
        Button("Save vote"){if let choice,let amount=Int(paid),let full{Task{if await store.request("/vote",["meal":meal.id,"verdict":choice,"paid":amount,"filling":full]){dismiss()}}}}.disabled(store.busy || choice==nil || full==nil || !(1...10000).contains(Int(paid) ?? 0))
    }.navigationTitle("Your verdict").toolbar{ToolbarItem(placement:.cancellationAction){Button("Cancel"){dismiss()}}}}}
}
struct Community:View{
    @EnvironmentObject var store:Store
    var body:some View{List{Section(store.state?.profile.uni ?? "University"){ForEach(store.personalMeals){m in NavigationLink{Discussion(id:m.id)}label:{VStack(alignment:.leading){Text(m.name).font(.headline);Text(m.comments.isEmpty ? "Start the discussion":"\(m.comments.count) recent comments").font(.subheadline).foregroundStyle(.secondary)}}}}}.navigationTitle("Community").refreshable{await store.request()}}
}
struct Discussion:View{
    let id:String
    @EnvironmentObject var store:Store
    @Local private var draft=""
    @Local private var nonce=UUID().uuidString
    var body:some View{if let m=store.state?.meals.first(where:{$0.id==id}){
        List{Section("Discussion"){if m.comments.isEmpty{Text("Be the first to share what you thought of this meal.")}
            ForEach(m.comments){c in VStack(alignment:.leading,spacing:5){Text(c.author).font(.headline);Text(c.body)}}}
            Section("Add a comment"){TextField("What should another student know?",text:$draft,axis:.vertical).lineLimit(2...6).disabled(store.busy)
                Button("Post comment"){let message=draft;Task{if await store.request("/comment",["meal":id,"body":message,"nonce":nonce]){draft="";nonce=UUID().uuidString}}}.disabled(store.busy || draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || draft.count>500)}
        }.navigationTitle(m.name).navigationBarTitleDisplayMode(.inline).refreshable{await store.request()}
    }}
}
struct Account:View{
    @EnvironmentObject var store:Store
    @Local private var name=""
    var body:some View{Form{
        Section("Your profile"){TextField("Display name",text:$name);Button("Save name"){Task{await store.request("/profile",["name":name])}}.disabled(store.busy || name==store.state?.profile.name || name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || name.count>48)}
        Section("Preferences"){NavigationLink(store.state?.profile.uni ?? "Choose university"){Universities()};BudgetControl()}
        Section("Your votes"){let voted=store.state?.meals.filter{$0.mine != nil} ?? [];if voted.isEmpty{Text("Your dish verdicts will appear here.").foregroundStyle(.secondary)};ForEach(voted){m in NavigationLink(m.name){Dish(id:m.id)}}}
    }.navigationTitle("Profile").onAppear{name=store.state?.profile.name ?? ""}}
}
