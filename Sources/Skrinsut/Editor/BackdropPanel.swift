import AppKit
import SwiftUI

final class BackdropModel: ObservableObject {
    @Published var settings: BackdropSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            onChange?(settings)
        }
    }
    var onChange: ((BackdropSettings) -> Void)?

    init(settings: BackdropSettings) { self.settings = settings }
}

/// Right-hand sidebar with the backdrop controls.
struct BackdropPanel: View {
    @ObservedObject var model: BackdropModel
    private let columns = Array(repeating: GridItem(.fixed(36), spacing: 8), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $model.settings.enabled) {
                    Text("Backdrop").font(.headline)
                }
                .toggleStyle(.switch)

                Group {
                    Picker("", selection: $model.settings.fill) {
                        ForEach(BackdropSettings.Fill.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    switch model.settings.fill {
                    case .gradient: gradientPicker
                    case .solid: solidPicker
                    case .wallpaper: slider("Blur", value: $model.settings.blur, range: 0...40)
                    }

                    Divider()
                    slider("Padding", value: $model.settings.padding, range: 0...0.4, percent: true)
                    slider("Corner radius", value: $model.settings.innerRadius, range: 0...40)
                    slider("Outer radius", value: $model.settings.outerRadius, range: 0...60)
                    slider("Shadow", value: $model.settings.shadow, range: 0...1, percent: true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Aspect ratio").font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: $model.settings.aspect) {
                            ForEach(BackdropSettings.Aspect.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                    }

                    HStack {
                        Button("Randomize") {
                            model.settings.fill = .gradient
                            model.settings.gradientIndex = Int.random(in: 0..<GradientPreset.all.count)
                        }
                        Spacer()
                        Button("Reset") {
                            var fresh = BackdropSettings()
                            fresh.enabled = true
                            model.settings = fresh
                        }
                    }
                }
                .disabled(!model.settings.enabled)
                .opacity(model.settings.enabled ? 1 : 0.45)
            }
            .padding(14)
        }
        .frame(width: 236)
    }

    private var gradientPicker: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(GradientPreset.all.indices, id: \.self) { i in
                let preset = GradientPreset.all[i]
                RoundedRectangle(cornerRadius: 7)
                    .fill(LinearGradient(colors: preset.colors.map(Color.init(nsColor:)),
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 36, height: 36)
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(model.settings.gradientIndex == i ? Color.accentColor : Color.primary.opacity(0.15),
                                      lineWidth: model.settings.gradientIndex == i ? 2.5 : 1))
                    .onTapGesture { model.settings.gradientIndex = i }
            }
        }
    }

    private var solidPicker: some View {
        let binding = Binding<Color>(
            get: { Color(nsColor: model.settings.solidColor) },
            set: { model.settings.solidHex = NSColor($0).hexString }
        )
        return HStack(spacing: 8) {
            ColorPicker("Color", selection: binding, supportsOpacity: false)
            ForEach(["#FFFFFF", "#E9EBEE", "#1E1E1E", "#F5E6D3"], id: \.self) { hex in
                Circle().fill(Color(nsColor: NSColor(hex: hex)!))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.2)))
                    .frame(width: 20, height: 20)
                    .onTapGesture { model.settings.solidHex = hex }
            }
        }
    }

    private func slider(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, percent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(percent ? "\(Int((value.wrappedValue * 100).rounded()))%" : "\(Int(value.wrappedValue))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .controlSize(.small)
        }
    }
}
