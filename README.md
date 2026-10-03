# Automated Batch Process Controller (PID + ISA-88)

A simulated process-control system built on a Siemens S7-1200. The PLC runs a heated mixing tank through a recipe: it fills to a level, holds a temperature with a PID loop, mixes for a set time, then drains and counts the batch. A Python gateway reads the PLC over the S7 protocol and streams live values to a browser dashboard that can also send commands back.

## Overview

Batch processes in pharma, food, and specialty chemicals make a product one lot at a time by following a recipe: reach a level, hold a temperature for a time, then move on to the next step. I wanted to build that whole loop the way it is done on the plant floor, but without buying hardware, so the control logic is genuine S7-1200 code running in Siemens PLCSIM.

A simulator has no physical process behind it, so the temperature and level would never move on their own. To get around that, the PLC program includes a small first-order tank model that runs in the same fast interrupt as the controller. That gives the PID a live process to push against, and it is the reason you can watch a real closed loop settle inside the simulator. Around the PLC sits a two-way data path: an edge gateway written in Python and a single-file web dashboard.

The two things this project is really about are PID closed-loop temperature control and a recipe-driven step sequence in the ISA-88 style.

## What it does

- Three preset recipes. Each one sets a target temperature, a mix time, and a fill level. The operator selects one before starting.
- A five-step sequence: `IDLE -> FILLING -> HEATING -> MIXING -> DRAINING -> COMPLETE`, plus a `FAULT/HELD` state that overrides everything.
- `PID_Compact` holds the tank temperature at the recipe setpoint and produces a 0-100 % heater command every 100 ms.
- The inlet and outlet valves fill and drain the tank; the agitator runs during mixing; a contactor enables the heater during heating and mixing.
- A batch counter increments each time a batch finishes.
- E-Stop (wired normally closed, so 1 means healthy) and Abort both force the safe held state and turn every actuator off. A reset returns the machine to idle.
- The dashboard shows an animated tank (level and a colour that tracks temperature), a setpoint-versus-actual temperature trend, the current phase, the active recipe, heater percentage, batch count, alarms, and a batch history. It also has Start, Stop, Abort, Reset, and the three recipe buttons.

The recipes are:

| Recipe | Name | Temperature setpoint | Mix time | Fill level |
|:--|:--|:--|:--|:--|
| 1 | Product A | 60 C | 10 s | 80 % |
| 2 | Product B | 75 C | 20 s | 90 % |
| 3 | Product C | 50 C | 15 s | 70 % |

The step transitions are simple and readable: fill until the level reaches the recipe setpoint, heat until the temperature is within 1 C of setpoint, mix until the timer reaches the recipe time, and drain until the tank is nearly empty (2 %).

## How it works

The PLC holds all shared state in one global data block, `DB1 "BatchData"`. Three blocks do the work: `OB1` (ladder) latches Start/Stop and picks the recipe, `FB1 BatchSequence` (Structured Text) is the state machine, and `FB2 ProcessModel` (Structured Text) is the simulated tank. `PID_Compact` and `FB2` both run in `OB30`, a cyclic interrupt firing every 100 ms, so the controller has a constant sample time.

The gateway reads `DB1` by fixed byte offset over the S7 protocol, turns it into JSON, and publishes it on MQTT. The dashboard subscribes to that feed over a WebSocket. Commands travel the other way: a dashboard button publishes a small JSON message, the gateway receives it and pulses the matching command bit in `DB1`.

```
      TIA Portal (engineering PC)
             |  compile + download
             v
   +-------------------------------------------+
   |  S7-1200 program running in PLCSIM         |
   |    DB1 "BatchData"  (38 bytes, standard)   |
   |    OB1  ladder: Run latch + recipe select  |
   |    OB30 (100 ms): PID_Temp + ProcessModel  |
   |    FB1  BatchSequence (state machine)      |
   |    FB2  ProcessModel  (simulated tank)     |
   +-----------------------+-------------------+
                           |  S7 protocol (TCP 102), python-snap7
                           v
                   iot_gateway.py
             reads DB1 every 2 s, writes command bits
                           |
                           |  MQTT  (broker.hivemq.com)
                           |    1883 TCP for Python, 8884 WSS for the browser
                           v
                   dashboard.html  (opens in a browser)
             live tank + trend + alarms + Start/Stop/Abort/Reset
```

## Tech stack

| Area | Tool / part | Notes |
|:--|:--|:--|
| PLC | Siemens S7-1200 CPU 1214C DC/DC/DC | order `6ES7 214-1AG40-0XB0`, firmware V4.5 |
| Analog output board | SB 1232 AQ | order `6ES7 232-4HA30-0XB0`, gives `QW80` for the heater |
| Engineering software | TIA Portal V18 (STEP 7) | Structured Text and Ladder |
| Simulator | S7-PLCSIM | runs the program with no hardware |
| Controller | PID_Compact technology object | configured, not hand-coded |
| Gateway | Python 3, `python-snap7`, `paho-mqtt` | reads/writes the PLC, publishes MQTT |
| Messaging | MQTT via `broker.hivemq.com` | public broker, 1883 (TCP) and 8884 (WSS) |
| Dashboard | plain HTML/CSS/JS, `mqtt.js` | single file, drawn on a canvas |

## Repository structure

```
02_Batch_Controller/
â”œâ”€â”€ README.md
â””â”€â”€ code/
    â”œâ”€â”€ batch_controller_structured_text.st   PLC source: DB1 + FB1 + FB2 (Structured Text)
    â”œâ”€â”€ iot_gateway.py                         S7-to-MQTT edge gateway
    â””â”€â”€ dashboard.html                         single-file web dashboard
```

## What you need

No physical hardware is required. Everything runs on one Windows PC.

Software:

- TIA Portal V18 with STEP 7 and S7-PLCSIM installed.
- Python 3 (64-bit).
- Two Python packages:

```powershell
pip install python-snap7 paho-mqtt
```

`python-snap7` is a wrapper around a native `snap7.dll`. Recent versions ship the DLL inside the wheel, so `import snap7` usually just works. If you get "could not find snap7 library", download snap7 from sourceforge, and copy `release\Windows\Win64\snap7.dll` next to `iot_gateway.py` or into `C:\Windows\System32`. Use the 64-bit DLL with 64-bit Python.

An internet connection is needed to run the dashboard, because it loads `mqtt.js` from a CDN and talks to the public MQTT broker.

## Setup and run

There are three parts: build the PLC program in TIA Portal, run the gateway, then open the dashboard. The PLC program is assembled in the TIA Portal GUI; the Structured Text for the data block and the two function blocks is provided in `code/batch_controller_structured_text.st`.

### A. Build and run the PLC program

1. Create a new project. Add the CPU 1214C DC/DC/DC (`6ES7 214-1AG40-0XB0`), firmware V4.5.
2. In Device view, drop an SB 1232 AQ signal board (`6ES7 232-4HA30-0XB0`) into the signal-board slot. It takes the analog output address `QW80`.
3. Select the CPU, open Properties, and under System and clock memory tick "Enable the use of clock memory byte". Leave it at `MB10`, which gives a 1 Hz bit at `M10.5`.
4. Create the PLC tag table with these names and addresses:

   | Name | Address | Meaning |
   |:--|:--|:--|
   | Start_Button | I0.0 | start the selected batch |
   | Stop_Button | I0.1 | stop / break the run latch |
   | E_Stop | I0.2 | emergency stop, normally closed (1 = healthy) |
   | Recipe1_Select | I0.3 | select recipe 1 |
   | Recipe2_Select | I0.4 | select recipe 2 |
   | Recipe3_Select | I0.5 | select recipe 3 |
   | Abort_Button | I0.6 | abort the current batch |
   | Inlet_Valve | Q0.0 | fills the tank |
   | Outlet_Valve | Q0.1 | drains the tank |
   | Agitator | Q0.2 | mixer motor |
   | Heater_Contactor | Q0.3 | heater power enable |
   | Alarm_Beacon | Q0.4 | flashing fault light |
   | Batch_Running | Q0.5 | running indicator |
   | Temperature_PV | IW64 | temperature transmitter (real hardware) |
   | Level_PV | IW66 | level transmitter (real hardware) |
   | Heater_Output | QW80 | analog heater command |
   | Run_Latch | M20.0 | latched run request |
   | Clock_1Hz | M10.5 | 1 Hz clock bit |

5. Create global data block `DB1` named `BatchData`. Add the variables in exactly this order, then open its Properties and untick "Optimized block access". The standard (non-optimized) layout is what lets the gateway read it by byte offset.

   | Offset | Name | Type | | Offset | Name | Type |
   |:--|:--|:--|:--|:--|:--|:--|
   | 0 | State | Int | | 28 | BatchCount | DInt |
   | 2 | ActiveRecipe | Int | | 32.0 | BatchRunning | Bool |
   | 4 | Temp_SP | Real | | 32.1 | BatchComplete | Bool |
   | 8 | Temp_PV | Real | | 32.2 | Fault | Bool |
   | 12 | Level_SP | Real | | 32.3 | EStop_Active | Bool |
   | 16 | Level_PV | Real | | 34 | Alarm_Code | Int |
   | 20 | Heater_Output | Real | | 36.0 | Cmd_Start | Bool |
   | 24 | MixTime_SP | Int | | 36.1 | Cmd_Stop | Bool |
   | 26 | MixTime_Elapsed | Int | | 36.2 | Cmd_Abort | Bool |
   | | | | | 36.3 | Cmd_Reset | Bool |
   | | | | | 36.4 | Cmd_Recipe1 | Bool |
   | | | | | 36.5 | Cmd_Recipe2 | Bool |
   | | | | | 36.6 | Cmd_Recipe3 | Bool |

   Total size is 38 bytes. Set `Temp_PV`'s start value to `25.0` so the tank begins at ambient. The four status bits share byte 32, then the `Alarm_Code` integer pushes the command bits into their own byte (36). That isolation lets the gateway pulse a command byte without a read-modify-write that could clobber a status bit.

6. Create two Structured Text function blocks, `FB1 BatchSequence` and `FB2 ProcessModel`. For each, declare the interface variables shown at the top of that block in `batch_controller_structured_text.st`, then copy the block body from the same file. `FB1` takes three inputs (`StartReq`, `EStopOK`, `Clock1Hz`) and holds an `R_TRIG` for the start edge, an `R_TRIG` for the clock, a `TON_TIME` mix timer, and a `Time` preset. `FB2` needs no inputs and two temporary reals.
7. Add a `PID_Compact` technology object named `PID_Temp`. In its configuration set the input to the plain `Input` (not `Input_PER`, because the tank temperature is already in degrees), the output to `Output` (0-100 %), and the process value upper limit to `130.0` C. Under PID parameters enable manual entry and set proportional gain `3.0`, integral time `10.0 s`, derivative time `0.0 s`. These are hand-set values that bring the simulated tank to setpoint smoothly; they are not tuned for a real vessel.
8. Add a cyclic interrupt organization block `OB30` with a cycle time of `100 ms`, language Structured Text, and put two calls in it:

   ```scl
   "PID_Temp"(Setpoint := "BatchData".Temp_SP,
              Input    := "BatchData".Temp_PV,
              Output   => "BatchData".Heater_Output);
   "ProcessModel_DB"();
   ```

   Drag `FB2` into `OB30` once so TIA creates the `ProcessModel_DB` instance the second call uses. Call the PID first, then the model, so the model applies the freshest heater command.
9. Build `OB1` in ladder with three networks:
   - A self-latch for `Run_Latch`: energised by `Start_Button` or `Cmd_Start` or its own contact, in series with `NOT Stop_Button`, `NOT Cmd_Stop`, a normally-open contact on `E_Stop` (it reads 1 when healthy), `NOT Abort_Button`, and `NOT Cmd_Abort`.
   - Three MOVE rungs that write 1, 2, or 3 into `BatchData.ActiveRecipe` when `Recipe1_Select`/`Cmd_Recipe1`, `Recipe2_Select`/`Cmd_Recipe2`, or `Recipe3_Select`/`Cmd_Recipe3` is pressed.
   - A call to `FB1 BatchSequence` with `StartReq := Run_Latch`, `EStopOK := E_Stop`, `Clock1Hz := Clock_1Hz`.
10. Compile the whole PLC, start PLCSIM, download to it, and switch it to RUN.

### B. Run the gateway

With PLCSIM in RUN:

```powershell
python code/iot_gateway.py
```

It connects to PLCSIM at `127.0.0.1`, rack 0, slot 1, reads `DB1`, and publishes to `iiot/batch/demo01/telemetry` every 2 seconds. It also subscribes to `iiot/batch/demo01/cmd` for commands. The session id `demo01` is set near the top of the file; change it if you want your own namespace on the public broker, and use the same value in the dashboard.

### C. Open the dashboard

Double-click `code/dashboard.html`. It opens in your browser and connects to the broker on its own. Make sure the Session field reads `demo01` (or whatever you set in the gateway). Live values start updating within a couple of seconds, and the Start/Stop/Abort/Reset and recipe buttons send commands back to the PLC.

