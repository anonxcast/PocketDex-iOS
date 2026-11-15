import SwiftUI
import UIKit

struct SaveStateSlotInfo: Identifiable, Equatable {
  var id: Int { slot }
  let slot: Int
  let exists: Bool
  let modified: Date?
  let thumbURL: URL?

  var isAuto: Bool { slot == RomLibrary.autoSaveSlot }
  var title: String { isAuto ? "Auto" : "Slot \(slot)" }
}

/// Picker for numbered save states with screenshots — load, overwrite, or save into an empty slot.
struct SaveStateSheet: View {
  @EnvironmentObject private var engine: EmulatorEngine
  @Environment(\.dismiss) private var dismiss

  @State private var slots: [SaveStateSlotInfo] = []
  @State private var busySlot: Int?
  @State private var confirmOverwrite: Int?
  @State private var confirmDelete: Int?
  private let deleteRed = Color(red: 0.95, green: 0.28, blue: 0.28)

  private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

  private var autoSlot: SaveStateSlotInfo? { slots.first(where: \.isAuto) }
  private var manualSlots: [SaveStateSlotInfo] { slots.filter { !$0.isAuto } }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          if let auto = autoSlot {
            Text("AUTO SAVE")
              .font(CETheme.sans(11, weight: .bold))
              .tracking(0.8)
              .foregroundStyle(CETheme.muted)
              .padding(.horizontal, 4)
            slotCard(auto)
          }
          Text("MANUAL")
            .font(CETheme.sans(11, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(CETheme.muted)
            .padding(.horizontal, 4)
            .padding(.top, 4)
          LazyVGrid(columns: columns, spacing: 12) {
            ForEach(manualSlots) { slot in
              slotCard(slot)
            }
          }
        }
        .padding(16)
      }
      .background(CETheme.bg)
      .navigationTitle("Save States")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
            .font(CETheme.sans(15, weight: .semibold))
            .foregroundStyle(CETheme.crystal)
        }
      }
      .onAppear { reload() }
      .confirmationDialog(
        overwriteTitle,
        isPresented: Binding(
          get: { confirmOverwrite != nil },
          set: { if !$0 { confirmOverwrite = nil } }
        ),
        titleVisibility: .visible
      ) {
        if let slot = confirmOverwrite {
          Button("Overwrite", role: .destructive) {
            save(to: slot)
            confirmOverwrite = nil
          }
          Button("Cancel", role: .cancel) { confirmOverwrite = nil }
        }
      }
      .confirmationDialog(
        deleteTitle,
        isPresented: Binding(
          get: { confirmDelete != nil },
          set: { if !$0 { confirmDelete = nil } }
        ),
        titleVisibility: .visible
      ) {
        if let slot = confirmDelete {
          Button("Delete", role: .destructive) {
            delete(slot)
            confirmDelete = nil
          }
          Button("Cancel", role: .cancel) { confirmDelete = nil }
        }
      }
    }
  }

  private var overwriteTitle: String {
    guard let slot = confirmOverwrite else { return "Overwrite?" }
    return slot == RomLibrary.autoSaveSlot ? "Overwrite Auto save?" : "Overwrite slot \(slot)?"
  }

  private var deleteTitle: String {
    guard let slot = confirmDelete else { return "Delete?" }
    return slot == RomLibrary.autoSaveSlot ? "Delete Auto save?" : "Delete slot \(slot)?"
  }

  @ViewBuilder
  private func slotCard(_ info: SaveStateSlotInfo) -> some View {
    let busy = busySlot == info.slot
    VStack(alignment: .leading, spacing: 8) {
      ZStack {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(CETheme.hover)
        if let url = info.thumbURL, let ui = UIImage(contentsOfFile: url.path) {
          Image(uiImage: ui)
            .resizable()
            .interpolation(.none)
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
          VStack(spacing: 6) {
            Image(systemName: info.exists ? "photo" : "plus.square.dashed")
              .font(.system(size: 22, weight: .semibold))
              .foregroundStyle(CETheme.muted)
            Text(info.exists ? "No preview" : "Empty")
              .font(CETheme.sans(11, weight: .medium))
              .foregroundStyle(CETheme.muted)
          }
        }
        if busy {
          Color.black.opacity(0.45)
          ProgressView().tint(.white)
        }
      }
      .aspectRatio(1.5, contentMode: .fit)
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(info.exists ? CETheme.crystal.opacity(0.55) : CETheme.border, lineWidth: 1)
      )

      HStack {
        Text(info.title)
          .font(CETheme.sans(13, weight: .bold))
          .foregroundStyle(info.isAuto ? CETheme.crystal : CETheme.text)
        if info.isAuto {
          Text("every 3 min · after battles · on pause")
            .font(CETheme.sans(9, weight: .medium))
            .foregroundStyle(CETheme.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        Spacer()
        if let date = info.modified {
          Text(Self.shortDate(date))
            .font(CETheme.mono(10))
            .foregroundStyle(CETheme.muted)
        }
      }

      if info.exists {
        HStack(spacing: 8) {
          slotActionButton("Load", busy: busy, fill: CETheme.crystal.opacity(0.9), ink: .black) {
            load(info.slot)
          }
          slotActionButton("Save", busy: busy, fill: CETheme.card, ink: CETheme.text, stroke: CETheme.border) {
            confirmOverwrite = info.slot
          }
        }
        slotActionButton("Delete", busy: busy, fill: deleteRed.opacity(0.08), ink: deleteRed, stroke: deleteRed, strokeWidth: 1.5) {
          confirmDelete = info.slot
        }
      } else {
        slotActionButton("Save here", busy: busy, fill: CETheme.crystal.opacity(0.9), ink: .black) {
          save(to: info.slot)
        }
      }
    }
    .padding(10)
    .background(CETheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(info.isAuto ? CETheme.crystal.opacity(0.55) : CETheme.border, lineWidth: info.isAuto ? 1.5 : 1)
    )
    .contextMenu {
      if info.exists {
        Button("Load") { load(info.slot) }
        Button("Overwrite") { confirmOverwrite = info.slot }
        Button("Delete", role: .destructive) { delete(info.slot) }
      } else {
        Button("Save here") { save(to: info.slot) }
      }
    }
  }

  private func slotActionButton(
    _ title: String,
    busy: Bool,
    fill: Color,
    ink: Color,
    stroke: Color? = nil,
    strokeWidth: CGFloat = 1,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Text(title)
        .font(CETheme.sans(12, weight: .bold))
        .foregroundStyle(ink)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(fill, in: Capsule())
        .overlay {
          if let stroke {
            Capsule().stroke(stroke, lineWidth: strokeWidth)
          }
        }
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .disabled(busy)
  }

  private func reload() {
    slots = engine.listSaveStateSlots()
  }

  private func save(to slot: Int) {
    busySlot = slot
    engine.saveState(to: slot) { ok in
      busySlot = nil
      reload()
      if ok { dismiss() }
    }
  }

  private func load(_ slot: Int) {
    busySlot = slot
    engine.loadState(from: slot) { ok in
      busySlot = nil
      if ok { dismiss() }
      else { reload() }
    }
  }

  private func delete(_ slot: Int) {
    engine.deleteState(slot: slot)
    reload()
  }

  private static func shortDate(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateStyle = .short
    f.timeStyle = .short
    return f.string(from: date)
  }
}
