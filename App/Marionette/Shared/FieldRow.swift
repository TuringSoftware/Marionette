// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// A form row of a title and a field: side by side, field trailing; at accessibility text sizes the
/// field goes under its title, with the row's full width.
struct FieldRow<Field: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var field: Field
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(_ title: LocalizedStringKey, @ViewBuilder field: () -> Field) {
        self.title = title
        self.field = field()
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                field.multilineTextAlignment(.leading)
            }
        } else {
            LabeledContent(title) { field.multilineTextAlignment(.trailing) }
        }
    }
}
