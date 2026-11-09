hisashi\
a small shelf in the macbook notch.

hover the notch and it opens: now playing, today, notifications, a file shelf,\
focus, and [seikatsu](https://github.com/danylo-morhun/seikatsu).\
pure black, system type, color only when something happens.

notifications grow out of the camera instead of the system banner,\
with the app's own buttons. they stay in notification center.\
needs accessibility access; without it the system banners stay.

the notifications tab mirrors notification center, one stack per app.\
it needs full disk access, and clearing needs the "show notification centre"\
shortcut set to ctrl option command f19 (keyboard shortcuts, mission control).

claude code shows while it works: a turning spark and the time beside the camera,\
the current step in the open notch, questions and finished replies as notices.\
point its hooks at `scripts/claude-hook.sh` (userpromptsubmit, pretooluse,\
posttooluse, notification, stop, sessionend).

early. the shell works, the tabs come next.

`scripts/run.sh` builds and launches it. needs command line tools, not xcode.
