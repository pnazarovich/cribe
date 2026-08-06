import AppKit
import SwiftUI

/// Настройки Универсального доступа, от которых зависит вид стекла. Системное уведомление
/// приходит и когда приложение неактивно, поэтому подложка переключается вживую.
@MainActor
final class HUDAccessibility: ObservableObject {
    static let shared = HUDAccessibility()

    @Published private(set) var reduceTransparency: Bool
    @Published private(set) var reduceMotion: Bool
    @Published private(set) var increaseContrast: Bool

    private init() {
        let workspace = NSWorkspace.shared
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        // Наблюдателя не снимаем: объект живёт столько же, сколько приложение.
        workspace.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Уведомление доставляется на главную очередь — это и есть MainActor.
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    private func reload() {
        let workspace = NSWorkspace.shared
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
    }
}

/// Общий рецепт стекла HUD-а: его носят и пилюля диктовки, и карточки. Стек слоёв снизу
/// вверх: материал за окном → тёмный скрим → контент → волосяной кант → верхний блик →
/// пробегающий отблеск. Один слой стекла, без шума и без стекла на стекле.
///
/// Форму задаёт вызывающий: капсула у пилюли, скруглённый прямоугольник у карточки.
/// Вложенные скругления держим концентрическими — радиус минус отступ от края.
enum Glass {
    /// Плотность тонировки стекла — вкус пользователя: максимально прозрачное.
    /// Сознательно ниже рекомендованных 0.15–0.25: читаемость держат не заливкой, а блюром
    /// самого материала, светлым кантом и тенями под контентом. Крутится одной строкой.
    static let scrim: Double = 0.06
    /// При «Увеличить контраст» стекло темнеет до почти непрозрачного.
    static let contrastScrim: Double = 0.30
}

/// Слои 1–2: материал, сэмплирующий содержимое за окном, и тёмный скрим поверх него.
struct GlassPlate<S: Shape>: View {
    let shape: S
    /// Радиус скругления для маски материала; nil — капсула (её радиус равен половине
    /// высоты и известен только в рантайме).
    var cornerRadius: CGFloat?

    @ObservedObject private var accessibility = HUDAccessibility.shared

    var body: some View {
        if accessibility.reduceTransparency {
            // Фолбэк без прозрачности: сплошная тёмная плашка, всё остальное как было.
            shape.fill(Color(white: 0.12))
        } else {
            ZStack {
                HUDBackdrop(cornerRadius: cornerRadius)
                shape.fill(
                    .black.opacity(accessibility.increaseContrast ? Glass.contrastScrim : Glass.scrim)
                )
            }
        }
    }
}

/// Слой 4: волосяной кант в 1 px, светлый сверху и почти прозрачный снизу.
/// Именно асимметрия отличает стекло от «картинной рамы» равномерной обводки.
struct GlassRim<S: InsettableShape>: View {
    let shape: S

    @ObservedObject private var accessibility = HUDAccessibility.shared

    var body: some View {
        if accessibility.reduceTransparency || accessibility.increaseContrast {
            shape.strokeBorder(.white.opacity(0.25), lineWidth: 1)
        } else {
            shape.strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.55), location: 0),
                        .init(color: .white.opacity(0.14), location: 0.4),
                        .init(color: .white.opacity(0.08), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
        }
    }
}

/// Слой 5: внутренний блик — размытая дуга по верхней кромке, гаснущая к середине.
struct GlassSheen<S: InsettableShape>: View {
    let shape: S

    var body: some View {
        shape
            .inset(by: 1)
            .stroke(.white.opacity(0.15), lineWidth: 0.5)
            .blur(radius: 1)
            .mask { LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center) }
    }
}

/// Блик: одна диагональная полоса света пробегает по плашке сразу после того, как пружина
/// поставила её на место. Ровно один раз за появление — это момент «стекло поймало свет»,
/// а не бесконечный шиммер (тот читался бы рекламой).
struct SpecularSweep<S: Shape>: View {
    let shape: S

    @State private var travel: CGFloat = -1

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.18), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: geometry.size.width * 0.45, height: geometry.size.height * 2.4)
                .rotationEffect(.degrees(20))
                .offset(x: travel * geometry.size.width * 1.1, y: -geometry.size.height * 0.7)
        }
        .clipShape(shape)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.5).delay(0.35)) { travel = 1 }
        }
    }
}

/// Слой 1: единственный слой стекла — системный материал, который блюрит содержимое ЗА окном.
/// SwiftUI-материалы (`.ultraThinMaterial` и прочие) на macOS фон за окном не видят и дают
/// плоскую серую плашку, поэтому подложка тут именно AppKit-овая.
struct HUDBackdrop: NSViewRepresentable {
    /// nil — капсула: радиус равен половине высоты.
    var cornerRadius: CGFloat?

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = MaskedEffectView()
        view.cornerRadius = cornerRadius
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        // Ключевая строка: панель никогда не становится key, а `.active` не даёт стеклу потухнуть.
        view.state = .active
        view.isEmphasized = true
        // Материал берёт вариант из оформления вью, а HUD всегда тёмный.
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        (view as? MaskedEffectView)?.cornerRadius = cornerRadius
    }
}

/// Форму материалу задаёт только `maskImage`: слой, который рисует WindowServer, надёжно не режут
/// ни `clipShape`, ни CALayer-маска. Маска — растягиваемая 9-частная картинка, поэтому одна
/// годится на любой габарит плашки; пересобираем её лишь при смене радиуса.
private final class MaskedEffectView: NSVisualEffectView {
    var cornerRadius: CGFloat? {
        didSet {
            guard cornerRadius != oldValue else { return }
            needsLayout = true
        }
    }

    private var maskedRadius: CGFloat?

    override func layout() {
        super.layout()
        guard bounds.height > 0 else { return }
        let radius = cornerRadius ?? bounds.height / 2
        guard maskedRadius.map({ abs($0 - radius) > 0.5 }) ?? true else { return }
        maskedRadius = radius
        maskImage = .roundedMask(radius: radius)
    }
}

extension NSImage {
    /// Сторона 2r+1: центральная полоса шириной в точку, её растяжение и даёт плашку
    /// любого габарита с неискажёнными углами.
    fileprivate static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
