# vhs tape for docs/demo.gif — records the real mrtop binary running on the
# synthetic state from docs/demo-state.sh (no real project data).
#
#   bash docs/demo-state.sh /tmp/mm-demo
#   make build
#   vhs docs/demo.tape
#
Output docs/demo.gif

Set FontSize 14
Set Width 1500
Set Height 720
Set Padding 10
Set Framerate 12
Set TypingSpeed 40ms

Hide
Type `alias mrwatch='MRTOP_FAKE_DAEMON=1 ./bin/mrtop /tmp/mm-demo #'`
Enter
Type "clear"
Enter
Show

Type "mrwatch top"
Sleep 600ms
Enter
Sleep 5s
Type "j"
Sleep 300ms
Type "k"
Sleep 500ms
Enter
Sleep 4s
