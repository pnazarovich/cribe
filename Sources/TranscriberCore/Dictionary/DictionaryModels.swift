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
    DictionaryEntry(canonical: "deploy", variants: ["деплой", "деплоить", "задеплой"]),
    DictionaryEntry(canonical: "commit", variants: ["коммит", "закоммить", "коміт"]),
    DictionaryEntry(canonical: "Tailscale", variants: ["тейлскейл", "тэйлскейл"]),
    DictionaryEntry(canonical: "backend", variants: ["бэкенд", "бекенд", "бэкэнд"]),
    DictionaryEntry(canonical: "frontend", variants: ["фронтенд", "фронтэнд"]),
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
    DictionaryEntry(canonical: "WHOOP", variants: ["вуп", "хуп"], stem: false),
    DictionaryEntry(canonical: "Wispr Flow", variants: ["виспр флоу", "виспер флоу", "віспр флоу", "уиспер флоу"], stem: false),
    DictionaryEntry(canonical: "Hermes", variants: ["гермес", "хермес", "хермез"]),
    DictionaryEntry(canonical: "CFv1", variants: ["си эф ви один", "сиэфви один", "сі еф ві один"], stem: false),
    DictionaryEntry(canonical: "m2fit.com.ua", variants: ["эм два фит ком юа", "эм два фит", "ем два фіт"], stem: false),
    DictionaryEntry(canonical: "Claude.MD", variants: ["клод эм дэ", "клод точка эм дэ", "клод мд", "клод ем де"], stem: false),
    DictionaryEntry(canonical: "Klientomat", variants: ["клиентомат", "клієнтомат", "клиентомата", "клиентомату"]),
    DictionaryEntry(canonical: "openclaw-billing-proxy", variants: ["опенкло биллинг прокси", "опен кло биллинг прокси", "опенкло білінг проксі"], stem: false),
    DictionaryEntry(canonical: "ChatGPT", variants: ["чат гпт", "чатгпт", "чат джипити", "чат жпт", "чат джіпіті"]),
    DictionaryEntry(canonical: "Clo3D", variants: ["кло три дэ", "кло 3д", "кло три де"], stem: false),
    DictionaryEntry(canonical: "OpenAI", variants: ["опен эй ай", "опенаи", "опен аи", "опен ей ай"], stem: false),
    DictionaryEntry(canonical: "ClinicCards", variants: ["клиник кардс", "клиниккардс", "клінік кардс"]),
]
