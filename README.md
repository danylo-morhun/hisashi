# hisashi

macOS app that turns the MacBook notch into a panel for music, the day's calendar,
notifications, Claude Code sessions and CI runs.

the closed notch shows what is going on: the playing track with album art and an equalizer,
volume and brightness levels instead of the system popup, other apps' notifications
the progress of a running Claude Code session and a CI run you started. hovering the notch opens the panel.

## tabs

| tab           | what it shows                                                                                |
| :------------ | :------------------------------------------------------------------------------------------- |
| now playing   | the current track from any player, with playback controls                                    |
| today         | today's events from all calendars with a join button for calls, weather, battery and a timer |
| notifications | the Notification Center list, one stack per app, with clearing                               |
| shelf         | not built yet                                                                                |
| status        | Claude Code sessions and GitHub Actions runs in one feed, work in progress first             |
| seikatsu      | not built yet                                                                                |

## notifications

banners from other apps are hidden and shown in the notch instead, with the app's own buttons.
the notifications stay in Notification Center. an event that several calendars announce
is shown once.

## Claude Code

point every Claude Code hook event at `scripts/claude-hook.sh`. the script sends the hook data
to hisashi over a unix socket and exits at once when hisashi is not running.
the notch then shows the elapsed time of the current turn, the current step and finished replies.
questions with single-choice answers can be answered in the notch.
clicking a session brings its terminal to the front.

## CI

runs come from GitHub Actions on the repos pushed to in the last week, for every account
`gh` is signed in to (tokens are taken with `gh auth token`). a finished run shows as a notice:
a pass goes away by itself, a failure stays with a rerun button.
while a run of yours is going, the closed notch shows a branch sign and its time;
beside a working Claude Code session the sign sits next to the spark. clicking a run opens it on GitHub.

## permissions

| permission                  | used for                                                     |
| :-------------------------- | :----------------------------------------------------------- |
| Accessibility               | notifications in the notch, volume and brightness keys       |
| Full Disk Access            | the notifications tab and sender photos                      |
| System Audio Recording Only | the equalizer. only levels are computed, nothing is recorded |
| Calendars                   | the today tab                                                |
| Location                    | weather                                                      |

without location access, weather uses a city from
`~/Library/Application Support/Hisashi/config.json`:

```json
{ "city": "Katowice" }
```

clearing notifications needs the "Show Notification Centre" shortcut set to
ctrl option command F19 in System Settings, Keyboard Shortcuts, Mission Control.

## run

requires macOS 15 or later and Xcode Command Line Tools. Xcode itself is not needed.

```bash
scripts/dev-cert.sh   # once: local signing identity, keeps permissions across rebuilds
scripts/run.sh        # build, stop the running copy, start the new one
```

`scripts/bundle.sh` builds `build/Hisashi.app` without starting it.

now playing reads the private MediaRemote framework through a small helper library
loaded into `/usr/bin/perl`, because MediaRemote only answers Apple-signed processes.
