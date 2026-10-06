#!/bin/bash
# Sandboxed scenarios for the generated watchdog. Every path is under $FAKE.
export FAKE=/tmp/arctic-sim/root
reset_fake() {
  rm -rf "$FAKE"; mkdir -p "$FAKE/sys/class/hwmon/hwmon2" "$FAKE/pci/0000:19:00.0/hwmon/hwmon5" "$FAKE/pci/0000:67:00.0/hwmon/hwmon6"
  mkdir -p "$FAKE/bin"; cp /tmp/arctic-sim/bin/* "$FAKE/bin/"; touch "$FAKE/cc_active"
  local h=$FAKE/sys/class/hwmon/hwmon2 c
  echo arctic_fan > $h/name
  for c in 1 2 3 4 5 6 7 8 9 10; do echo 255 > $h/pwm$c; echo 0 > $h/fan${c}_input; done
  echo 14470 > $h/fan2_input; echo 15029 > $h/fan3_input
  for p in 19:00.0:hwmon5:21000 67:00.0:hwmon6:22000; do
    IFS=: read a b hw t <<< "$p"; d=$FAKE/pci/0000:$a:$b/hwmon/$hw
    echo amdgpu > $d/name; echo junction > $d/temp2_label; echo $t > $d/temp2_input
  done
}
run_case() {
  local name="$1"; shift
  reset_fake
  echo "===== $name"
  bash /tmp/arctic-sim/wd-sim.sh > /tmp/arctic-sim/$name.log 2>&1 &
  local pid=$!
  "$@"
  sleep 1
  if kill -0 $pid 2>/dev/null; then echo "process: still running"; kill -TERM $pid 2>/dev/null; wait $pid 2>/dev/null; echo "exit after TERM=$?";
  else wait $pid; echo "process: exited with $?"; fi
  echo "status file: $(cat $FAKE/status 2>/dev/null || echo MISSING)"
  echo "pwm: $(for c in 1 2 3; do printf 'pwm%s=%s ' $c $(cat $FAKE/sys/class/hwmon/hwmon2/pwm$c 2>/dev/null); done)"
  echo "last log: $(tail -1 /tmp/arctic-sim/$name.log)"
  grep -E 'CRITICAL|FAIL|forcing|invalid|unused|missing|fake safe-high' /tmp/arctic-sim/$name.log | sort | uniq -c | head -8
}
sleep_s() { sleep "$1"; }
run_case healthy sleep_s 9
run_case fan2-stall bash -c 'sleep 6; echo 0 > $FAKE/sys/class/hwmon/hwmon2/fan2_input; sleep 16; echo 14000 > $FAKE/sys/class/hwmon/hwmon2/fan2_input; sleep 4'
run_case both-stall bash -c 'sleep 6; echo 0 > $FAKE/sys/class/hwmon/hwmon2/fan2_input; echo 0 > $FAKE/sys/class/hwmon/hwmon2/fan3_input; sleep 16'
run_case tach-missing bash -c 'sleep 6; rm -f $FAKE/sys/class/hwmon/hwmon2/fan3_input; sleep 6'
run_case tach-garbage bash -c 'sleep 6; echo abc > $FAKE/sys/class/hwmon/hwmon2/fan3_input; sleep 6'
run_case unused-pwm bash -c 'sleep 6; echo 180 > $FAKE/sys/class/hwmon/hwmon2/pwm1; sleep 6'
run_case gpu-channel-zero bash -c 'sleep 6; echo 0 > $FAKE/sys/class/hwmon/hwmon2/pwm2; sleep 6'
run_case pwm-write-fail bash -c 'chmod u+w $FAKE/sys/class/hwmon/hwmon2/pwm2; echo 200 > $FAKE/sys/class/hwmon/hwmon2/pwm2; chmod 444 $FAKE/sys/class/hwmon/hwmon2/pwm2; sleep 6'
run_case coolercontrol-inactive bash -c 'sleep 6; rm -f $FAKE/cc_active; sleep 6'
