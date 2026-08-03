import FountainKit
import SwiftUI

/// Edits the `Title:` block as a form.
///
/// The same block is always editable as raw text in the source pane — this is a
/// second view onto it, not a separate store. That makes round-tripping the
/// whole job: key order, each entry's inline-versus-indented style, custom keys
/// this form has no field for, and `_**BOLD UNDERLINE**_` emphasis all have to
/// survive a trip through here untouched.
///
/// Only 7 of the 17 scripts in the reference library have a title page, so
/// "none yet" is the common case and creating one must be a normal action
/// rather than an error state.
struct TitlePageInspector: View {
    @Bindable var model: ScreenplayModel
    @Environment(\.dismiss) private var dismiss

    @State private var draft = TitlePage()
    @State private var original: TitlePage?

    /// Fields the form shows explicitly. The corpus writes the draft date as
    /// both `Draft Date:` and `Date:` — whichever the author used is kept, and
    /// this list only decides what gets a labelled row.
    private static let fields: [(key: String, label: String, multiline: Bool)] = [
        ("Title", "Title", false),
        ("Credit", "Credit", false),
        ("Author", "Author", false),
        ("Source", "Source", false),
        ("Draft Date", "Draft date", false),
        ("Contact", "Contact", true),
        ("Copyright", "Copyright", false),
        ("Notes", "Notes", true)
    ]

    /// Anything the author wrote that this form has no row for. Shown so it is
    /// visibly preserved rather than silently carried.
    private var customEntries: [TitlePage.Entry] {
        let known = Set(Self.fields.map { $0.key.lowercased() } + ["date"])
        return draft.entries.filter { !known.contains($0.key.lowercased()) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(Self.fields, id: \.key) { field in
                        if field.multiline {
                            LabeledContent(field.label) {
                                TextEditor(text: binding(for: field.key))
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(height: 62)
                                    .scrollContentBackground(.hidden)
                                    .background(Color(nsColor: .textBackgroundColor))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        } else {
                            TextField(field.label, text: binding(for: field.key))
                                .accessibilityIdentifier("titlepage.\(field.key.lowercased())")
                        }
                    }
                } header: {
                    Text(original == nil ? "New title page" : "Title page")
                } footer: {
                    if original == nil {
                        Text("This script has no title page yet. Filling anything in adds one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !customEntries.isEmpty {
                    Section("Also in this script") {
                        ForEach(customEntries, id: \.key) { entry in
                            LabeledContent(entry.key, value: entry.joinedValue)
                                .foregroundStyle(.secondary)
                        }
                        Text("Kept exactly as written.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if original != nil {
                    Button("Remove Title Page", role: .destructive) {
                        draft = TitlePage()
                        apply()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") { apply() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 560)
        .accessibilityIdentifier("titlepage.root")
        .onAppear {
            // The parse is debounced, so make sure the block being edited is the
            // one currently in the document.
            model.reparseNow()
            original = model.script.titlePage
            draft = original ?? TitlePage()
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: {
                if key == "Draft Date" {
                    return draft.value(for: "Draft Date") ?? draft.value(for: "Date") ?? ""
                }
                return draft.value(for: key) ?? ""
            },
            set: { newValue in
                // Keep the author's own spelling of the key.
                if key == "Draft Date", draft.value(for: "Date") != nil {
                    draft.setValue(newValue, for: "Date")
                } else {
                    draft.setValue(newValue, for: key)
                }
            }
        )
    }

    private func apply() {
        let updated = draft.applied(to: model.text, existing: original)
        if updated != model.text {
            model.text = updated
            model.reparseNow()
        }
        dismiss()
    }
}
