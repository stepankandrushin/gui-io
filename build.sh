#!/bin/zsh -f
# build.sh — build GuiIO.app on this Mac, sign it, put it in ~/Applications with its LaunchAgent and
# the gui client in ~/.local/bin, and (re)start it in the console user's session.
#
#   zsh build.sh
#   GUI_IO_SIGN='Apple Development: Jane Doe (AB12CD34EF)' zsh build.sh
#   GUI_IO_ID=com.example.gui-io zsh build.sh
#
# TCC ties the Screen Recording and Accessibility grants to the bundle id and the signing
# certificate, so both stay the same from one build to the next:
# - the identity is GUI_IO_SIGN, or else the first "Apple Development" identity in the keychain;
#   GUI_IO_SIGN=- signs ad hoc, which works but loses both grants at every rebuild;
# - the bundle id, which is also the LaunchAgent's label, is GUI_IO_ID, or else the installed
#   GuiIO.app's, or else Info.plist's.
# Over SSH the login keychain is locked, and codesign needs it: unlock it in the same connection
# first (security unlock-keychain ~/Library/Keychains/login.keychain-db). The new bundle replaces the
# old one by rename, never by overwriting the running binary (which would kill it with "Code
# Signature Invalid").
set -eu
cd ${0:A:h}
plistbuddy=/usr/libexec/PlistBuddy
apps=$HOME/Applications
dest=$apps/GuiIO.app
# PlistBuddy answers a missing file with "File Doesn't Exist, Will Create" on stdout, so ask only
# when there is one
installed=
if [[ -e $dest/Contents/Info.plist ]]; then
  installed=$($plistbuddy -c 'Print :CFBundleIdentifier' $dest/Contents/Info.plist 2>/dev/null || true)
fi
label=${GUI_IO_ID:-${installed:-$($plistbuddy -c 'Print :CFBundleIdentifier' Info.plist)}}
if [[ ! $label =~ '^[A-Za-z0-9.-]+$' ]]; then
  print -u2 "build.sh: $label is not a bundle id (letters, digits, dots and hyphens)"
  exit 1
fi
identity=${GUI_IO_SIGN-}
if [[ -z $identity ]]; then
  identity=$(security find-identity -v -p codesigning |
    sed -n 's/^ *[0-9]*) [0-9A-F]* "\(Apple Development: .*\)"$/\1/p' | head -n 1)
  if [[ -z $identity ]]; then
    print -u2 "build.sh: no Apple Development identity in the keychain: set GUI_IO_SIGN to one of" \
      "\`security find-identity -v -p codesigning\`, or to - for an ad-hoc signature (the grants" \
      "are then lost at every rebuild)"
    exit 1
  fi
fi
agent=$HOME/Library/LaunchAgents/$label.plist
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

mkdir -p $apps $HOME/.local/bin $HOME/Library/LaunchAgents $HOME/Library/Logs
stage=$(mktemp -d $apps/.GuiIO-build.XXXXXX)
trap 'rm -rf $stage' EXIT
app=$stage/GuiIO.app
mkdir -p $app/Contents/MacOS $app/Contents/Resources
cp Info.plist $app/Contents/Info.plist
# icon/AppIcon.iconset is drawn by icon/icon.py
iconutil -c icns -o $app/Contents/Resources/AppIcon.icns icon/AppIcon.iconset
commit=$(git rev-parse --short HEAD 2>/dev/null || print none)
[[ -z $(git status --porcelain -- gui-io.swift Info.plist icon/AppIcon.iconset 2>/dev/null) ]] || commit+=-dirty
$plistbuddy -c "Set :CFBundleIdentifier $label" -c "Set :CFBundleVersion $(date +%Y%m%d.%H%M%S)" \
  -c "Add :GuiIOCommit string $commit" $app/Contents/Info.plist

print "build.sh: compiling"
xcrun swiftc -O -swift-version 5 -target $(uname -m)-apple-macos14.0 -o $app/Contents/MacOS/gui-io gui-io.swift
print "build.sh: signing with $identity"
codesign --force --sign "$identity" $app
codesign --verify --strict $app
codesign -d -r- $app 2>&1 | sed -n 's/^designated => /build.sh: requirement: /p'

if [[ -n $installed && $installed != $label ]]; then
  print "build.sh: replacing $installed with $label, whose grants are asked for anew"
  launchctl bootout gui/$UID/$installed 2>/dev/null || true
  rm -f $HOME/Library/LaunchAgents/$installed.plist
fi
if [[ -e $dest ]]; then
  mv $dest $stage/GuiIO.old.app
fi
mv $app $dest
$lsregister -f $dest

sed -e "s|@HOME@|$HOME|g" -e "s|@LABEL@|$label|g" launchagent.plist > $stage/agent.plist
if launchctl print gui/$UID/$label >/dev/null 2>&1; then
  if cmp -s $stage/agent.plist $agent; then
    print "build.sh: restarting $label"
    launchctl kickstart -k gui/$UID/$label
  else
    print "build.sh: LaunchAgent changed, reloading $label"
    launchctl bootout gui/$UID/$label || true
    cp $stage/agent.plist $agent
    launchctl bootstrap gui/$UID $agent
  fi
else
  print "build.sh: loading $label"
  cp $stage/agent.plist $agent
  launchctl bootstrap gui/$UID $agent
fi

install -m 755 gui $HOME/.local/bin/gui
print "build.sh: installed $dest ($label $($plistbuddy -c 'Print :CFBundleVersion' $dest/Contents/Info.plist)-$commit), $agent, ~/.local/bin/gui"
