import AppKit
import SwiftUI

/// Стекло обычных окон: настроек, онбординга и словаря. У HUD-а стекло своё
/// (`Panel/GlassStyle.swift`) — тёмное, всегда активное, живёт над чужим контентом.
/// Здесь оно светлое, следует за активностью окна и служит подложкой самого окна.
///
/// Слоёв ровно два: материал окна (сэмплирует то, что за окном) и полупрозрачные плашки
/// секций поверх него. Третьего блюра нет и быть не может — сэмплировать ему нечего:
/// за плашкой уже не обои, а размытая подложка окна.

/// Подложка окна. SwiftUI-материалы на macOS содержимое за окном не видят и дают плоскую
/// серую заливку, поэтому подложка тут AppKit-овая — как и у HUD-а.
struct WindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        // В отличие от HUD-а окно бывает активным и неактивным — и должно это показывать.
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        // Окно закрашивает свой фон непрозрачным цветом раньше, чем до него доберётся
        // материал: без этих двух строк подложка блюрит не обои, а заливку окна.
        guard let window = view.window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
    }
}

extension View {
    /// Прозрачное окно: сквозь настройки, онбординг и словарь видно то, что под ними.
    func glassWindow() -> some View {
        modifier(GlassWindow())
    }

    /// Стеклянная плашка секции или карточки внутри окна.
    func glassPanel(cornerRadius: CGFloat = 10) -> some View {
        glassPanel(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// То же стекло произвольной формы — капсула у полос и пилюль.
    func glassPanel<S: InsettableShape>(in shape: S) -> some View {
        modifier(GlassPanel(shape: shape))
    }
}

private struct GlassWindow: ViewModifier {
    @ObservedObject private var accessibility = HUDAccessibility.shared

    func body(content: Content) -> some View {
        if accessibility.reduceTransparency {
            content
        } else {
            content.background(WindowBackdrop().ignoresSafeArea())
        }
    }
}

private struct GlassPanel<S: InsettableShape>: ViewModifier {
    let shape: S

    @ObservedObject private var accessibility = HUDAccessibility.shared

    func body(content: Content) -> some View {
        if accessibility.reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor), in: shape)
        } else if #available(macOS 26.0, *) {
            // Системное стекло само разбирается со слоями, кантом и оформлением.
            content.glassEffect(.regular, in: shape)
        } else {
            // До macOS 26: заливка системным цветом плашки, приглушённая до полупрозрачной,
            // плюс волосяной кант. Цвет системный — светлую и тёмную тему он держит сам.
            content
                .background(
                    Color(nsColor: .controlBackgroundColor)
                        .opacity(accessibility.increaseContrast ? 0.95 : 0.5),
                    in: shape
                )
                .overlay { shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1) }
        }
    }
}
