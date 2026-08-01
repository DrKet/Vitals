# Shared by build-app.sh and verify-app.sh so the two can never derive a
# different version string for the same commit — verify-app.sh's version
# check would be meaningless if it could drift from what build-app.sh stamped.
#
# CFBundleShortVersionString comes from `git describe --tags`, in full: never
# truncated with --abbrev=0 (that reports the nearest tag's name even when
# HEAD is many commits past it — "never fabricate a number" applies to
# version strings too) and always with --dirty (an uncommitted tree must not
# report a clean tag's version). Falls back to an explicit dev form when
# there is no tag reachable at all.
vitals_require_git() {
    local root="$1"
    if ! git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "error: $root is not a git checkout — the version comes from git history (see AGENTS.md: never fabricate a number), so building outside a git checkout isn't supported" >&2
        return 1
    fi
}

vitals_version() {
    local root="$1"
    local version
    version="$(git -C "$root" describe --tags --dirty 2>/dev/null || true)"
    if [ -z "$version" ]; then
        local sha
        sha="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
        version="0.0.0-dev+$sha"
    fi
    printf '%s\n' "$version"
}

vitals_build_number() {
    local root="$1"
    git -C "$root" rev-list --count HEAD 2>/dev/null || echo ""
}
