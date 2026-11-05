# Only labelled EV_KEY records from the same input node can approve.
NF == 4 && $1 ~ /^\/dev\/input\/event[0-9]+:$/ && $2 == "EV_KEY" {
  if ($3 == "KEY_VOLUMEDOWN" && $4 == "DOWN") cancel=1
  if ($3 == "KEY_VOLUMEUP" && $4 == "UP" && down[$1]) approved=1
  if ($3 == "KEY_VOLUMEUP" && $4 == "DOWN") down[$1]=1
}
END {
  if (cancel) print "cancel"
  else if (approved) print "accept"
  else print "waiting"
}
