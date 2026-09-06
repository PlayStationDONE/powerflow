import AppKit
import PowerFlowKit
import SwiftUI

/// One row of the per-app draw list, plus the system remainder.
struct DrawRow: Identifiable, Equatable {
    let id: Int32
    let name: String
    let watts: Double
    /// Nil for the system remainder, which uses a symbol instead.
    let icon: NSImage?
    let isSystem: Bool

    /// Icons are compared by identity: they never change for a given pid, and
    /// NSImage has no useful value equality.
    static func == (a: DrawRow, b: DrawRow) -> Bool {
        a.id == b.id && a.name == b.name && a.watts == b.watts && a.isSystem == b.isSystem
    }
}

/// "If you unplug now" - the pack's remaining energy divided by what the
/// machine is actually drawing.
struct RuntimeCard: View {
    let text: String?
    let s: Scale

    var body: some View {
        HStack(spacing: s(Ref.rowIconGap)) {
            Image(systemName: "battery.50")
                .font(.system(size: s(Ref.runtimeGlyph)))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Palette.batteryCase, Palette.batteryFill)
            Text(text ?? "--")
                .font(.system(size: s(Ref.runtimeFontSize), weight: .semibold))
                .foregroundStyle(Palette.label)
            Spacer(minLength: 0)
            Text("left if you unplug")
                .font(.system(size: s(Ref.runtimeCaptionSize), weight: .regular))
                .foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, s(Ref.runtimeInset))
        .frame(width: s(Ref.contentWidth), height: s(Ref.runtimeHeight))
        .background(
            RoundedRectangle(cornerRadius: s(Ref.runtimeHeight) / 2, style: .continuous)
                .fill(Palette.surface)
        )
    }
}

/// The list: the heaviest apps, then everything else the machine spends power
/// on. The two together account for the whole system load shown in the
/// diagram above.
struct AppDrawList: View {
    let rows: [DrawRow]
    let s: Scale

    /// Bars compare applications with each other. The system remainder is
    /// usually the largest number on screen - a laptop spends most of its power
    /// on the display and the idle floor - and letting it set the scale would
    /// flatten every app bar to nothing.
    /// The remainder is the number people most often misread, so say plainly
    /// what is in it.
    static let systemRowExplanation = """
        The display, GPU, and everything the kernel does not bill to one of         your apps. WindowServer is the big one: it runs as a system user, so         its power cannot be read or charged to the app that caused it, even         though app drawing is what keeps it busy. Not an idle figure.
        """

    private var maxAppWatts: Double {
        max(rows.filter { !$0.isSystem }.map(\.watts).max() ?? 1, 0.001)
    }

    /// Fixed so the panel does not resize as apps come and go.
    private var rowsAreaHeight: CGFloat {
        CGFloat(Ref.appRowCount + 1) * s(Ref.rowHeight) + CGFloat(Ref.appRowCount) * s(Ref.rowGap)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: s(Ref.rowGap)) {
            Text("DRAW BY APP")
                .font(.system(size: s(Ref.sectionFontSize), weight: .semibold))
                .tracking(s(Ref.sectionTracking))
                .foregroundStyle(Palette.muted)
                .padding(.bottom, s(Ref.sectionRowGap - Ref.rowGap))

            VStack(alignment: .leading, spacing: s(Ref.rowGap)) {
                ForEach(rows) { row in
                    rowView(row)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Spacer(minLength: 0)
            }
            .frame(width: s(Ref.contentWidth), height: rowsAreaHeight, alignment: .top)
        }
        .frame(width: s(Ref.contentWidth), alignment: .leading)
    }

    @ViewBuilder
    private func rowView(_ row: DrawRow) -> some View {
        let radius = s(Ref.rowHeight) / 2
        // No bar behind the remainder: it is on a different scale from the
        // apps and would read as a comparison it is not.
        let share = row.isSystem ? 0 : min(1, max(0, row.watts / maxAppWatts))

        HStack(spacing: s(Ref.rowIconGap)) {
            Group {
                if let icon = row.icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: row.isSystem ? "gearshape.fill" : "app.dashed")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Palette.muted)
                }
            }
            .frame(width: s(Ref.rowIcon), height: s(Ref.rowIcon))

            Text(row.name)
                .font(.system(size: s(Ref.rowFontSize), weight: .regular))
                .foregroundStyle(row.isSystem ? Palette.muted : Palette.label)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: s(Ref.rowIconGap))

            Text(Format.appWatts(row.watts))
                .font(.system(size: s(Ref.rowFontSize), weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText(value: row.watts))
                .foregroundStyle(row.isSystem ? Palette.muted : Palette.energy)
        }
        .padding(.horizontal, s(Ref.rowInset))
        .frame(width: s(Ref.contentWidth), height: s(Ref.rowHeight))
        .help(row.isSystem ? Self.systemRowExplanation : "\(row.name) — CPU energy attributed to this app by the kernel")
        .background(alignment: .leading) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Palette.surface)
                // A share bar in the same proportional spirit as the ribbons.
                if share > 0 {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Palette.rowBar)
                        .frame(width: max(s(Ref.rowHeight), s(Ref.contentWidth) * share))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}
