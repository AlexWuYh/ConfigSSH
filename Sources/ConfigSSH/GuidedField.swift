import SwiftUI

/// One form field with its name, whether it is required, what it means, and an example shown as
/// the placeholder. A problem replaces the explanation in red as soon as the value is wrong.
struct GuidedField<Accessory: View>: View {
    enum Requirement {
        case required, optional

        var label: String { self == .required ? "必填" : "选填" }
    }

    let title: String
    var requirement: Requirement = .optional
    let help: String
    let example: String
    @Binding var text: String
    var problem: String?
    var isDisabled = false
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(title).font(.body.weight(.medium))
                Text(requirement.label)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .foregroundStyle(requirement == .required ? BrandPalette.accent : Color.secondary)
                    .background((requirement == .required ? BrandPalette.accent : Color.secondary).opacity(0.14), in: Capsule())
                Spacer()
            }
            HStack(spacing: 8) {
                TextField(title, text: $text, prompt: Text("例如 \(example)"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .disabled(isDisabled)
                    .accessibilityLabel(title)
                accessory()
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }
}

extension GuidedField where Accessory == EmptyView {
    init(title: String, requirement: Requirement = .optional, help: String, example: String,
         text: Binding<String>, problem: String? = nil, isDisabled: Bool = false) {
        self.init(title: title, requirement: requirement, help: help, example: example, text: text,
                  problem: problem, isDisabled: isDisabled) { EmptyView() }
    }
}
