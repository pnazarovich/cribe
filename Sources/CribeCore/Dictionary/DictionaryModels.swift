import Foundation

public struct DictionaryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var canonical: String
    public var variants: [String]
    public var stem: Bool

    public init(id: UUID = UUID(), canonical: String, variants: [String], stem: Bool = true) {
        self.id = id
        self.canonical = canonical
        self.variants = variants
        self.stem = stem
    }
}

public let defaultEntries: [DictionaryEntry] = [
    DictionaryEntry(canonical: "GitHub", variants: ["гитхаб", "гіт хаб", "гит хаб"]),
    DictionaryEntry(canonical: "deploy", variants: ["деплой", "деплоить", "задеплой", "деплу", "задеплу"]),
    DictionaryEntry(canonical: "commit", variants: ["коммит", "закоммить", "коміт"]),
    DictionaryEntry(canonical: "Tailscale", variants: ["тейлскейл", "тэйлскейл"]),
    DictionaryEntry(canonical: "backend", variants: ["бэкенд", "бекенд", "бэкэнд"]),
    DictionaryEntry(canonical: "frontend", variants: ["фронтенд", "фронтэнд"]),
    DictionaryEntry(canonical: "webhook", variants: ["вебхук", "вэбхук", "веб хук", "вебхуків"]),
    DictionaryEntry(canonical: "API", variants: ["апи", "апі"], stem: false),
    DictionaryEntry(canonical: "Docker", variants: ["докер"]),
    DictionaryEntry(canonical: "nginx", variants: ["нжинкс", "энджинкс", "енджинкс"]),
    DictionaryEntry(canonical: "Telegram", variants: ["телеграм", "телеграмм"]),
    DictionaryEntry(canonical: "pull request", variants: ["пул реквест", "пулреквест"]),
    DictionaryEntry(canonical: "merge", variants: ["мердж", "мёрдж", "мерж"]),
    DictionaryEntry(canonical: "Swift", variants: ["свифт", "свіфт"]),
    DictionaryEntry(canonical: "Python", variants: ["питон", "пайтон", "пітон"]),
    DictionaryEntry(canonical: "TypeScript", variants: ["тайпскрипт", "тайпскріпт"]),
    DictionaryEntry(canonical: "Claude", variants: ["клод"]),
    DictionaryEntry(canonical: "Whisper", variants: ["виспер", "уиспер", "віспер"]),
    DictionaryEntry(canonical: "VPS", variants: ["впс"], stem: false),
    DictionaryEntry(canonical: "SSH", variants: ["эсэсаш", "ссш"], stem: false),
    DictionaryEntry(canonical: "localhost", variants: ["локалхост", "локал хост"]),
    DictionaryEntry(canonical: "Claude.MD", variants: ["клод эм дэ", "клод точка эм дэ", "клод мд", "клод ем де"], stem: false),
    DictionaryEntry(canonical: "ChatGPT", variants: ["чат гпт", "чатгпт", "чат джипити", "чат жпт", "чат джіпіті"]),
    DictionaryEntry(canonical: "OpenAI", variants: ["опен эй ай", "опенаи", "опен аи", "опен ей ай"], stem: false),
    DictionaryEntry(canonical: "Kubernetes", variants: ["кубернетес", "кубернетис", "кубернетіс", "кубер"]),
    DictionaryEntry(canonical: "PostgreSQL", variants: ["постгрес", "постгре", "постгрескуэль", "постгрескьюэль"]),
    // Redis: без stem — иначе основа «редис» съедает «редиску».
    DictionaryEntry(canonical: "Redis", variants: ["редис", "рэдис", "редіс"], stem: false),
    DictionaryEntry(canonical: "npm", variants: ["энпиэм", "эн пи эм", "нпм", "ен пі ем"], stem: false),
    DictionaryEntry(canonical: "Xcode", variants: ["иксод", "икскод", "эксод", "ікскод"]),
    DictionaryEntry(canonical: "Figma", variants: ["фигма", "фігма"]),
    DictionaryEntry(canonical: "Slack", variants: ["слак", "слэк", "слек"]),
    DictionaryEntry(canonical: "Notion", variants: ["ноушен", "ноушн", "ношн", "нотион"]),
    DictionaryEntry(canonical: "Linux", variants: ["линукс", "лінукс"]),
    DictionaryEntry(canonical: "JSON", variants: ["джейсон", "джсон", "жсон"]),
    // Node.js и React — без stem: основы «нод» и «реакт» иначе ловят «нодой», «реактор».
    DictionaryEntry(canonical: "Node.js", variants: ["ноуд джей эс", "нод джей эс", "ноджиэс", "нод жс"], stem: false),
    DictionaryEntry(canonical: "React", variants: ["реакт", "реэкт"], stem: false),
    DictionaryEntry(canonical: "pipeline", variants: ["пайплайн", "пипелайн", "піплайн"]),
    DictionaryEntry(canonical: "rollback", variants: ["роллбэк", "ролбэк", "роллбек", "ролбек"]),
    DictionaryEntry(canonical: "staging", variants: ["стейджинг", "стэйджинг", "стейджінг"]),
    DictionaryEntry(canonical: "production", variants: ["продакшен", "продакшн", "продакшін"]),
]
