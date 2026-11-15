import SwiftUI
import UIKit

/// Settings › Support — ROMs that need an exact companion pin (and Expand status).
struct SupportQueuePanel: View {
  @State private var pending: [CompanionRomIdentity.Record] = []
  @State private var sharePayload: SharePayload?
  @State private var copied = false

  var body: some View {
    VStack(spacing: 12) {
      Text("Unknown or best-effort GBA hacks land here when you open them. Share the queue to pin companion profiles. Expand/zoom still needs a WIDE CRC table — that isn’t automatic.")
        .font(CETheme.sans(12))
        .foregroundStyle(CETheme.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)

      HStack(spacing: 10) {
        Button {
          sharePayload = SharePayload(
            items: [CompanionRomIdentity.exportQueueText()],
            subject: "PocketDex support queue"
          )
        } label: {
          Label("Share queue", systemImage: "square.and.arrow.up")
            .font(CETheme.sans(14, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(CETheme.text)
            .background(CETheme.card, in: RoundedRectangle(cornerRadius: CETheme.radius))
            .overlay(RoundedRectangle(cornerRadius: CETheme.radius).stroke(CETheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)

        Button {
          UIPasteboard.general.string = CompanionRomIdentity.exportQueueText()
          copied = true
          DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
          Label(copied ? "Copied" : "Copy JSON", systemImage: copied ? "checkmark" : "doc.on.doc")
            .font(CETheme.sans(14, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(CETheme.accent)
            .background(CETheme.card, in: RoundedRectangle(cornerRadius: CETheme.radius))
            .overlay(RoundedRectangle(cornerRadius: CETheme.radius).stroke(CETheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
      }

      if pending.isEmpty {
        Text("Queue empty — open a new GBA hack and it’ll show up here if companion isn’t pinned yet.")
          .font(CETheme.sans(13))
          .foregroundStyle(CETheme.muted)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(14)
          .background(CETheme.card, in: RoundedRectangle(cornerRadius: CETheme.radius))
          .overlay(RoundedRectangle(cornerRadius: CETheme.radius).stroke(CETheme.border, lineWidth: 1))
      } else {
        VStack(spacing: 0) {
          ForEach(Array(pending.enumerated()), id: \.element.id) { index, rec in
            if index > 0 { Divider().background(CETheme.border) }
            pendingRow(rec)
          }
        }
        .padding(.vertical, 4)
        .background(CETheme.card, in: RoundedRectangle(cornerRadius: CETheme.radius))
        .overlay(RoundedRectangle(cornerRadius: CETheme.radius).stroke(CETheme.border, lineWidth: 1))

        Button(role: .destructive) {
          CompanionRomIdentity.clearPending()
          pending = []
        } label: {
          Text("Clear queue")
            .font(CETheme.sans(13, weight: .semibold))
            .foregroundStyle(CETheme.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
      }
    }
    .onAppear { pending = CompanionRomIdentity.loadPending() }
    .sheet(item: $sharePayload) { payload in
      ActivityShareSheet(items: payload.items, subject: payload.subject)
    }
  }

  private func pendingRow(_ rec: CompanionRomIdentity.Record) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(rec.displayName ?? rec.title.ifEmpty(rec.fileName))
          .font(CETheme.sans(15, weight: .semibold))
          .foregroundStyle(CETheme.text)
          .lineLimit(2)
        Spacer(minLength: 8)
        Text(rec.matchLabel)
          .font(CETheme.sans(11, weight: .semibold))
          .foregroundStyle(CETheme.muted)
      }
      Text("\(rec.code) · \(rec.fileName)")
        .font(CETheme.sans(12))
        .foregroundStyle(CETheme.muted)
        .lineLimit(1)
      if let sha1 = rec.sha1 {
        Text(sha1)
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(CETheme.muted.opacity(0.9))
          .lineLimit(1)
      } else {
        Text("SHA-1 pending (re-open the game)")
          .font(CETheme.sans(11))
          .foregroundStyle(CETheme.muted)
      }
      HStack(spacing: 8) {
        labelChip(rec.configId.map { "profile \($0)" } ?? "no profile")
        labelChip(rec.wideSupported == true ? "Expand OK" : "Expand needs WIDE")
      }
    }
    .padding(14)
    .contextMenu {
      if let sha1 = rec.sha1 {
        Button {
          UIPasteboard.general.string = sha1
        } label: {
          Label("Copy SHA-1", systemImage: "doc.on.doc")
        }
      }
      Button(role: .destructive) {
        CompanionRomIdentity.removePending(id: rec.id)
        pending = CompanionRomIdentity.loadPending()
      } label: {
        Label("Remove", systemImage: "trash")
      }
    }
  }

  private func labelChip(_ text: String) -> some View {
    Text(text)
      .font(CETheme.sans(10, weight: .semibold))
      .foregroundStyle(CETheme.muted)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(CETheme.hover, in: Capsule())
  }
}

private extension String {
  func ifEmpty(_ fallback: String) -> String {
    trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : self
  }
}

private struct SharePayload: Identifiable {
  let id = UUID()
  let items: [Any]
  let subject: String
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
  let items: [Any]
  var subject: String = ""

  func makeUIViewController(context: Context) -> UIActivityViewController {
    let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
    vc.setValue(subject, forKey: "subject")
    return vc
  }

  func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
