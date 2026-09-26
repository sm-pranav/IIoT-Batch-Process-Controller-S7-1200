# =============================================================
#  Automated Batch Process Controller - IoT Gateway
#  Reads live data from the Siemens PLC (running in PLCSIM) over
#  the S7 protocol, then publishes it to an MQTT broker as JSON.
#  It also listens for control commands coming back from the
#  web dashboard and writes them into the PLC.
#
#  Data flow:  PLCSIM  --S7-->  this script  --MQTT-->  dashboard.html
# =============================================================
#
#  ---------------------------------------------------------------
#  1) INSTALL THE PYTHON PACKAGES
#  ---------------------------------------------------------------
#       pip install python-snap7 paho-mqtt
#
#  ---------------------------------------------------------------
#  2) INSTALL THE snap7 NATIVE LIBRARY (Windows)
#  ---------------------------------------------------------------
#  python-snap7 is only a wrapper. It needs the snap7 DLL.
#
#    Option A (easiest, newer python-snap7): the wheel already
#    ships the DLL. If `import snap7` works and the script runs,
#    you are done - skip to step 3.
#
#    Option B (if you get "could not find snap7 library"):
#      - Download snap7 from https://sourceforge.net/projects/snap7/
#      - Unzip it. Go to  release\Windows\Win64\
#      - Copy  snap7.dll  into one of these:
#            * the same folder as this script, OR
#            * C:\Windows\System32
#      - Use the 64-bit DLL with 64-bit Python (very important).
#
#  ---------------------------------------------------------------
#  3) FIND PLCSIM's IP ADDRESS
#  ---------------------------------------------------------------
#  When the PLC runs inside PLCSIM on the same laptop, use the
#  loopback address 127.0.0.1. PLCSIM answers S7 requests there.
#  Rack = 0, Slot = 1 for an S7-1200.
#
#  If you use PLCSIM Advanced or a real PLC, set PLC_IP to that
#  device's IP address instead.
#
#  ---------------------------------------------------------------
#  4) COMMON CONNECTION PROBLEMS
#  ---------------------------------------------------------------
#  - "TCP : Unreachable peer"  -> PLCSIM not in RUN, or wrong IP.
#  - Reads all zeros / garbage -> DB1 is OPTIMIZED. Open DB1 in
#    TIA Portal, Properties -> uncheck "Optimized block access",
#    recompile, download again.
#  - "Item not available"      -> DB number wrong, or DB too small.
#  - Firewall prompt           -> allow Python through the firewall.
# =============================================================

import json
import time
import uuid

import snap7
from snap7.client import Client
from snap7.util import get_int, get_dint, get_real, get_bool, set_bool
import paho.mqtt.client as mqtt

# -------------------------------------------------------------
#  CONFIGURATION  (edit these if needed)
# -------------------------------------------------------------
PLC_IP   = "127.0.0.1"     # PLCSIM on this machine
PLC_RACK = 0
PLC_SLOT = 1
DB_NUMBER = 1              # "BatchData"
DB_SIZE   = 38             # bytes - matches the DB1 layout exactly

MQTT_BROKER = "broker.hivemq.com"
MQTT_PORT   = 1883
PUBLISH_PERIOD = 2.0       # seconds between publishes

# A short session id keeps our topics private on the public broker.
# The web dashboard must use the SAME id. Change "demo01" to your own.
SESSION_ID = "demo01"
TOPIC_TELEMETRY = f"iiot/batch/{SESSION_ID}/telemetry"
TOPIC_COMMAND   = f"iiot/batch/{SESSION_ID}/cmd"

# Text lookups so the dashboard receives friendly labels
STATE_TEXT = {
    0:  "IDLE",
    10: "FILLING",
    20: "HEATING",
    30: "MIXING",
    40: "DRAINING",
    50: "COMPLETE",
    90: "FAULT / HELD",
}
RECIPE_TEXT = {
    0: "None",
    1: "Product A",
    2: "Product B",
    3: "Product C",
}
ALARM_TEXT = {
    0: "No active alarms",
    1: "EMERGENCY STOP pressed",
    2: "Batch ABORTED by operator",
}

# Byte offset inside DB1 where the command bits live (see the .st file).
# The seven command bits sit alone in byte 36, so we can pulse a command
# without ever disturbing a status bit.
CMD_BYTE = 36
CMD_BITS = {          # command name -> bit position in byte 36
    "start":   0,
    "stop":    1,
    "abort":   2,
    "reset":   3,
    "recipe1": 4,
    "recipe2": 5,
    "recipe3": 6,
}


# -------------------------------------------------------------
#  PLC HELPERS
# -------------------------------------------------------------
def connect_plc():
    """Keep trying until PLCSIM answers. Returns a connected client."""
    client = Client()
    while True:
        try:
            print(f"[PLC ] Connecting to {PLC_IP} rack {PLC_RACK} slot {PLC_SLOT} ...")
            client.connect(PLC_IP, PLC_RACK, PLC_SLOT)
            if client.get_connected():
                print("[PLC ] Connected.")
                return client
        except Exception as exc:
            print(f"[PLC ] Not ready yet ({exc}). Retrying in 3 s. "
                  f"Is PLCSIM in RUN?")
        time.sleep(3)


def read_plc(client):
