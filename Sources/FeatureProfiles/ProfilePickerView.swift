#if os(tvOS)
import SwiftUI
import CoreModels
import CoreUI

/// tvOS profile picker — the "Who's watching?" screen.
///
/// Selection-only. Tapping a tile activates that profile; there is no Edit
/// mode and no per-tile account toggles. Profile editing lives in Settings →
/// Profile after selection. An "Add Profile" tile is shown only when the
/// caller passes a non-nil `onAddProfile` (i.e. from Settings → "Manage
/// Profiles"); the launch picker hides it.
public struct ProfilePickerView: View {
    private let profiles: [Profile]
    private let activeProfileID: String?
    private let title: LocalizedStringResource
    private let onSelect: (Profile) -> Void
    private let onAddProfile: (() -> Void)?
    /// Opens the focused profile's settings. When non-nil an Edit affordance
    /// appears under whichever tile has focus.
    private let onEditProfile: ((Profile) -> Void)?
    /// Creates a restricted profile directly. A separate entry point rather than
    /// a toggle buried in the editor, the way YouTube splits "Add account" from
    /// "Add a kid account": the decision is clearest at the moment of creation,
    /// and it means the restriction is on from the profile's first second rather
    /// than after a trip through Settings.
    private let onAddKidsProfile: (() -> Void)?
    private let onCancel: (() -> Void)?
    private let onOpenSettings: (() -> Void)?
    private let showsPINLock: (Profile) -> Bool

    public init(
        profiles: [Profile],
        activeProfileID: String?,
        title: LocalizedStringResource = "Who's watching?",
        onSelect: @escaping (Profile) -> Void,
        onAddProfile: (() -> Void)? = nil,
        onEditProfile: ((Profile) -> Void)? = nil,
        onAddKidsProfile: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil,
        onOpenSettings: (() -> Void)? = nil,
        showsPINLock: @escaping (Profile) -> Bool = { $0.showsPINLock }
    ) {
        self.profiles = profiles
        self.activeProfileID = activeProfileID
        self.title = title
        self.onSelect = onSelect
        self.onAddProfile = onAddProfile
        self.onEditProfile = onEditProfile
        self.onAddKidsProfile = onAddKidsProfile
        self.onCancel = onCancel
        self.onOpenSettings = onOpenSettings
        self.showsPINLock = showsPINLock
    }


    /// What currently holds focus. Richer than a profile id because each column
    /// now has two focusable controls — the tile and its own Edit button — and
    /// the column needs to stay "open" while either of them is focused.
    @FocusState private var focus: PickerFocus?

    /// The profile the focus is currently within, whichever of its two controls
    /// holds it. Reveals that column's Edit button.
    private var focusedProfileID: String? {
        switch focus {
        case let .profile(id), let .edit(id): return id
        default: return nil
        }
    }

    /// Guards the one-time programmatic initial focus so later re-renders don't
    /// keep yanking focus back to the default tile.
    @State private var didSetInitialFocus = false
    /// The row's visible width, so a household that fits is centred rather
    /// than left-aligned in its scroll view.
    @State private var rowViewportWidth: CGFloat = 0

    /// The tile that should hold focus when the picker first appears: the
    /// last-active profile (so resuming is a single click), falling back to the
    /// first profile on a first-ever launch with no active profile.
    private var defaultFocusID: String? {
        activeProfileID ?? profiles.first?.id
    }

    /// Each column's own Edit button, directly beneath its avatar.
    ///
    /// Rendered for every profile rather than as one shared slot, so it reads as
    /// belonging to the profile it sits under. It's always present in the layout
    /// — a button that only *existed* while focused could never receive the Down
    /// press meant to reach it — but it only becomes visible when focus is
    /// somewhere in that column, so the row stays quiet while you scan across it.
    @ViewBuilder
    private func editButton(for profile: Profile, onEdit: @escaping (Profile) -> Void) -> some View {
        let isRevealed = focusedProfileID == profile.id
        Button {
            onEdit(profile)
        } label: {
            Text("Edit")
                .font(.system(size: 21, weight: .semibold))
        }
        .buttonStyle(ProfilePickerPillStyle())
        .focused($focus, equals: .edit(profile.id))
        .opacity(isRevealed ? 1 : 0)
        // Unreachable when hidden, so the focus engine can't land on an
        // invisible control coming from an odd angle.
        .disabled(!isRevealed)
        .animation(.easeOut(duration: 0.15), value: isRevealed)
    }

    public var body: some View {
        VStack(spacing: 36) {
            Text(title)
                .font(.system(size: 54, weight: .bold))
                .tracking(-0.8)
                .foregroundStyle(ProfilePickerLayout.titleInk)

            // One horizontal run rather than a wrapping grid. Profiles are a
            // short list you scan left-to-right, and a single row keeps the
            // Edit affordance directly under whatever has focus — with a grid
            // it would have to sit under a *row*, which reads as belonging to
            // all of them.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: ProfilePickerLayout.tileSpacing) {
                    ForEach(profiles) { profile in
                        VStack(spacing: 14) {
                            ProfileTile(profile: profile, showsLock: showsPINLock(profile)) {
                                onSelect(profile)
                            }
                            .focused($focus, equals: .profile(profile.id))

                            if let onEditProfile {
                                editButton(for: profile, onEdit: onEditProfile)
                            }
                        }
                        // Keep each profile's tile and its Edit button in one
                        // focus region, so Down reaches that column's button
                        // rather than the nearest one in another column.
                        .focusSection()
                    }
                    if let onAddProfile {
                        AddProfileTile(
                            title: "Add Profile",
                            systemImage: "plus",
                            action: onAddProfile
                        )
                        .focused($focus, equals: .add)
                    }
                    // Kept as its own tile: it is the only way to create a profile
                    // that is restricted from its first second (see
                    // `onAddKidsProfile`), and the add flow has no Kids step.
                    if let onAddKidsProfile {
                        AddProfileTile(
                            title: KidsProfileCopy.addTile,
                            systemImage: "figure.and.child.holdinghands",
                            action: onAddKidsProfile
                        )
                        .focused($focus, equals: .addKids)
                    }
                }
                .frame(minWidth: max(0, rowViewportWidth - ProfilePickerLayout.rowPadding * 2))
                .padding(.horizontal, ProfilePickerLayout.rowPadding)
                // Room for the focus lift and shadow, which would otherwise be
                // clipped by the scroll view's bounds.
                .padding(.vertical, 40)
            }
            .scrollClipDisabled()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowViewportWidth = $0 }
            .focusSection()

            if let onCancel {
                Button(action: onCancel) {
                    Text("Cancel").font(.system(size: 24, weight: .semibold))
                }
                .buttonStyle(ProfilePickerPillStyle())
                .padding(.top, 8)
                .focusSection()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 80)
        .overlay(alignment: .top) {
            HStack(alignment: .center) {
                ProfilePickerBrand()
                Spacer()
                if let onOpenSettings {
                    Button(action: onOpenSettings) {
                        Label("Settings", systemImage: "gearshape.fill")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 30, weight: .semibold))
                            .frame(width: 66, height: 66)
                    }
                    .buttonStyle(ProfilePickerPillStyle(shape: .circle))
                    .accessibilityIdentifier("profile-picker-settings")
                }
            }
            .padding(.horizontal, ProfilePickerLayout.chromeInset)
            .padding(.top, 56)
            // Full width, so Up from any tile reaches the gear.
            .focusSection()
            .ignoresSafeArea()
        }
        .background { ProfileBackgroundGradient() }
        .onAppear {
            prefetchAvatars()
            setInitialFocusIfNeeded()
        }
    }

    /// Move focus to the default tile (last-used profile, else first) once when
    /// the picker appears. tvOS's declarative `.defaultFocus` is unreliable with
    /// `LazyVGrid`, so we set the `@FocusState` explicitly after a short runloop
    /// hop — letting the focus engine finish its first pass — which dependably
    /// pre-selects the right tile.
    private func setInitialFocusIfNeeded() {
        guard !didSetInitialFocus else { return }
        didSetInitialFocus = true
        guard let target = defaultFocusID else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            focus = .profile(target)
        }
    }

    /// Warm the decoded-image cache for every profile photo as soon as the picker
    /// appears, so the tiles' `FallbackAsyncImage` seeds synchronously and the
    /// photos pop in with no neutral-placeholder gap. Cheap and fire-and-forget.
    private func prefetchAvatars() {
        #if canImport(UIKit)
        for profile in profiles {
            guard
                let raw = profile.avatarImageURL?.trimmingCharacters(in: .whitespaces),
                !raw.isEmpty,
                let url = URL(string: raw)
            else { continue }
            ArtworkImageCache.shared.prefetch(url, variant: .posterCard)
        }
        #endif
    }
}

/// What holds focus in the picker.
///
/// A plain profile id isn't enough now that each column owns two focusable
/// controls: the column has to stay revealed while focus sits on either the tile
/// or its Edit button, and the Add tiles need identities that can't collide with
/// a profile id.
private enum PickerFocus: Hashable {
    case profile(String)
    case edit(String)
    case add
    case addKids
}

/// A single selectable profile tile: a circular avatar with the name beneath it.
///
/// At rest the tile has **no background** — just the avatar and name. On focus
/// the avatar lifts (scale + deeper shadow) and gains a white ring, the tvOS
/// profile-picker treatment; the name sits below and never scales. A custom
/// `ButtonStyle` owns focus (with the system focus effect disabled) so there's
/// exactly one focus indicator.
///
/// Deliberately does NOT mark which profile is active. You're on this screen to
/// choose someone; which profile you happened to arrive as isn't information you
/// need, and marking it drew the eye to the least useful tile.
private struct ProfileTile: View {
    let profile: Profile
    let showsLock: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ProfileTileLabel(profile: profile, showsLock: showsLock)
        }
        .plozzCardFocusButtonStyle(
            ProfileTileButtonStyle(), cornerRadius: ProfilePickerLayout.avatarSize / 2,
            contentSuppliesProjection: true
        )
        .plozzCircularFocusStyle()
        .accessibilityLabel(profile.name)
        .accessibilityValue(showsLock ? Text(ProfileLockCopy.title) : Text(verbatim: ""))
    }
}

/// Focus treatment shared by the profile and "Add" tiles. Owning focus in a
/// `ButtonStyle` — rather than a `.plain` button with a manual overlay — keeps
/// tvOS from also painting its own focus plate, so the tile shows a single,
/// fully custom indicator. The focus scale is applied to the *avatar only*
/// (inside `ProfilePickerAvatarSlot`); here we just pass the press state down
/// so the name keeps a constant size.
private struct ProfileTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.profileTilePressed, configuration.isPressed)
    }
}

/// A fixed-size avatar slot. On focus the avatar, its badge and its shadow
/// scale up together and a white ring appears just outside the circle. The
/// focused size is always reserved, so focusing never nudges the row. The
/// shadow belongs to a plain filled circle behind the avatar, not to the
/// avatar's content.
private struct ProfilePickerAvatarSlot<Avatar: View, Badge: View>: View {
    /// Off for translucent content, which the shadow's disc would show through.
    var castsShadow = true
    @ViewBuilder var avatar: () -> Avatar
    @ViewBuilder var badge: () -> Badge
    @Environment(\.isFocused) private var isFocused
    @Environment(\.profileTilePressed) private var isPressed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var scale: CGFloat {
        guard isFocused else { return 1 }
        return isPressed ? ProfilePickerLayout.focusScale * 0.97 : ProfilePickerLayout.focusScale
    }

    var body: some View {
        let diameter = ProfilePickerLayout.avatarSize
        ZStack {
            if castsShadow {
                Circle()
                    .fill(ProfilePickerLayout.titleInk)
                    .frame(width: diameter - 4, height: diameter - 4)
                    .shadow(
                        color: ProfilePickerLayout.titleInk.opacity(isFocused ? 0.38 : 0.25),
                        radius: isFocused ? 30 : 20, y: isFocused ? 34 : 18
                    )
            }
            avatar()
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
            Circle()
                .strokeBorder(Color.white.opacity(0.85), lineWidth: ProfilePickerLayout.ringWidth)
                .frame(
                    width: diameter + ProfilePickerLayout.ringWidth * 2,
                    height: diameter + ProfilePickerLayout.ringWidth * 2
                )
                .opacity(isFocused ? 1 : 0)
            badge()
                .frame(width: diameter, height: diameter, alignment: .bottomTrailing)
        }
        .scaleEffect(scale)
        .frame(width: ProfilePickerLayout.slot, height: ProfilePickerLayout.slot)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isFocused)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isPressed)
    }
}

/// The white lock badge on a PIN-protected profile's avatar. Replaces the
/// inline lock beside the name on this screen; the tile's accessibility value
/// still announces the lock.
private struct ProfileLockBadge: View {
    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(ProfilePickerLayout.titleInk)
            .frame(width: 52, height: 52)
            .background {
                Circle()
                    .fill(Color.white.opacity(0.92))
                    .shadow(color: ProfilePickerLayout.titleInk.opacity(0.25), radius: 8, y: 6)
            }
            .padding(2)
            .accessibilityHidden(true)
    }
}

private struct ProfileTilePressedKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var profileTilePressed: Bool {
        get { self[ProfileTilePressedKey.self] }
        set { self[ProfileTilePressedKey.self] = newValue }
    }
}

/// The label content for a profile tile. Reads `\.isFocused` (the focusable
/// button propagates it) so the name gently emphasises on focus.
private struct ProfileTileLabel: View {
    let profile: Profile
    let showsLock: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(spacing: 14) {
            ProfilePickerAvatarSlot {
                ProfileAvatarView(profile: profile, size: ProfilePickerLayout.avatarSize)
            } badge: {
                if showsLock { ProfileLockBadge() }
            }

            ProfileNameLabel(profile: profile, showsLock: false)
                .font(ProfilePickerLayout.nameFont)
                .foregroundStyle(isFocused ? ProfilePickerLayout.focusedNameInk : ProfilePickerLayout.nameInk)
                .lineLimit(1)
        }
    }
}

/// A trailing "create something" tile: one frosted circle with a glyph. Two of
/// these can appear — an ordinary profile and a Kids Profile — mirroring how
/// YouTube offers "Add account" and "Add a kid account" side by side rather
/// than hiding the distinction behind a toggle. Only rendered when the caller
/// passes the matching closure; the launch picker shows neither.
private struct AddProfileTile: View {
    let title: LocalizedStringResource
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AddProfileTileLabel(title: title, systemImage: systemImage)
        }
        .plozzCardFocusButtonStyle(
            ProfileTileButtonStyle(), cornerRadius: ProfilePickerLayout.avatarSize / 2,
            contentSuppliesProjection: true
        )
        .plozzCircularFocusStyle()
    }
}

private struct AddProfileTileLabel: View {
    let title: LocalizedStringResource
    let systemImage: String

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(spacing: 14) {
            ProfilePickerAvatarSlot(castsShadow: false) {
                ZStack {
                    // A translucent fill over the static background, not a
                    // blur: a backdrop sample of a still gradient only
                    // reproduces the gradient.
                    Circle().fill(Color.white.opacity(isFocused ? 0.5 : 0.28))
                    Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1.5)
                    Image(systemName: systemImage)
                        .font(.system(size: 64, weight: .regular))
                        .foregroundStyle(ProfilePickerLayout.titleInk)
                }
            } badge: {
                EmptyView()
            }

            Text(title)
                .font(ProfilePickerLayout.nameFont)
                .foregroundStyle(isFocused ? ProfilePickerLayout.focusedNameInk : ProfilePickerLayout.nameInk)
                .lineLimit(1)
        }
    }
}

/// The picker's small controls (Edit, Cancel, the Settings gear): a light
/// translucent pill over the static background, solid white when focused.
private struct ProfilePickerPillStyle: ButtonStyle {
    enum Shape { case capsule, circle }
    var shape: Shape = .capsule

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, shape: shape)
    }

    private struct PillBody: View {
        let configuration: ButtonStyle.Configuration
        let shape: Shape
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .foregroundStyle(ProfilePickerLayout.titleInk)
                .padding(.horizontal, shape == .capsule ? 22 : 0)
                .frame(minHeight: 44)
                .background {
                    switch shape {
                    case .capsule: Capsule().fill(fill).shadow(color: shadow, radius: 12, y: 8)
                    case .circle: Circle().fill(fill).shadow(color: shadow, radius: 12, y: 8)
                    }
                }
                .contentShape(shape == .capsule ? AnyShape(Capsule()) : AnyShape(Circle()))
                .scaleEffect(isFocused ? (configuration.isPressed ? 1.04 : 1.1) : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isFocused)
        }

        private var fill: Color { isFocused ? .white : .white.opacity(0.5) }
        private var shadow: Color { ProfilePickerLayout.titleInk.opacity(isFocused ? 0.3 : 0) }
    }
}

/// The Plozz mark and name, top-leading like the tvOS profile picker.
private struct ProfilePickerBrand: View {
    var body: some View {
        HStack(spacing: 14) {
            Image("PlozzLogo")
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(width: 56, height: 56)
            Text(verbatim: "Plozz")   // l10n:content — app name
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(ProfilePickerLayout.titleInk)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Plozz"))
    }
}

/// Shared layout constants so a profile tile and the "Add Profile" tile size
/// identically.
private enum ProfilePickerLayout {
    /// The avatar IS the target on this screen, so it stays large; the tvOS
    /// picker's 190pt keeps six tiles (four profiles plus both Add tiles)
    /// comfortably inside the title-safe area.
    static let avatarSize: CGFloat = 190
    static let focusScale: CGFloat = 1.14
    static let ringWidth: CGFloat = 4
    /// The reserved avatar-slot size: the focused avatar plus its ring.
    static let slot: CGFloat = 228
    /// With the reserved slot, this leaves the concept's 64pt between resting
    /// avatars.
    static let tileSpacing: CGFloat = 26
    /// Row inset, inside the tvOS title-safe area.
    static let rowPadding: CGFloat = 40
    /// The logo and Settings gear sit on the 80pt side margins.
    static let chromeInset: CGFloat = 80
    static let nameFont: Font = .system(size: 28, weight: .semibold)
    /// Dark ink for the light background, independent of the app theme.
    static let titleInk = Color(red: 0.078, green: 0.149, blue: 0.239)
    static let nameInk = Color(red: 0.102, green: 0.180, blue: 0.278)
    static let focusedNameInk = Color(red: 0.043, green: 0.102, blue: 0.173)
}
#endif
