// ============================================================
// PROJECT : Automated Batch Process Controller (PID + ISA-88)
// PLATFORM: Siemens S7-1200 (CPU 1214C) - TIA Portal V18
// FILE    : Structured Text (SCL) source for DB1, FB1, FB2
// ============================================================
//
// HOW TO USE THIS FILE IN TIA PORTAL
// ----------------------------------
// You CANNOT paste this whole file in one go. TIA Portal keeps each
// block (DB1, FB1, FB2) separate. Do this:
//
//   1. Create the block first (see tia_portal_setup_guide.md, Section 5).
//   2. Open the block editor.
//   3. Copy ONLY that block's code from this file into the editor.
//        - For DB1: re-create the variables by hand in the DB table
//          using the exact names/types/order below (recommended for
//          beginners), OR use the "external source file" import.
//        - For FB1 / FB2: switch the block language to SCL, declare the
//          interface variables shown, then paste the code between
//          BEGIN ... END_FUNCTION_BLOCK.
//
// IMPORTANT: DB1 "BatchData" MUST be NON-OPTIMIZED (standard access) so
// the Python gateway (python-snap7) can read it by byte offset. Right-
// click DB1 -> Properties -> Attributes -> UNCHECK "Optimized block
// access". If you skip this, snap7 reads garbage.
//
// FB1 and FB2 can stay Optimized (that is fine and faster).
//
// PID_Temp (PID_Compact) is NOT in this file - it is a Technology Object
// you configure in the TIA Portal GUI and call from OB30 (see the setup
// guide, Section 4 and 6).
// ============================================================


// ============================================================
// DB1 : "BatchData"  (Global Data Block, STANDARD / NON-OPTIMIZED)
// ------------------------------------------------------------
// This is the single "shared memory" for the whole system. The HMI
// reads it, the PID reads/writes it, and the Python gateway reads it
// over S7. The BYTE OFFSET column is the data contract - the Python
// gateway and the dashboard rely on these exact offsets. DO NOT
// reorder the variables.
//
//  OFFSET  NAME              TYPE   NOTES
//  ------  ----------------  -----  --------------------------------
//    0.0   State             Int    0 IDLE 10 FILL 20 HEAT 30 MIX
//                                    40 DRAIN 50 COMPLETE 90 FAULT/HELD
//    2.0   ActiveRecipe      Int    0 none, 1 A, 2 B, 3 C
//    4.0   Temp_SP           Real   Temperature setpoint  (deg C)
//    8.0   Temp_PV           Real   Temperature actual    (deg C)
//   12.0   Level_SP          Real   Tank level setpoint   (%)
//   16.0   Level_PV          Real   Tank level actual     (%)
//   20.0   Heater_Output     Real   PID heater command    (0..100 %)
//   24.0   MixTime_SP        Int    Recipe mix time       (seconds)
//   26.0   MixTime_Elapsed   Int    Elapsed mix time      (seconds)
//   28.0   BatchCount        DInt   Completed batches
//   32.0   BatchRunning      Bool   TRUE while a phase is active
//   32.1   BatchComplete     Bool   TRUE after a finished batch
//   32.2   Fault             Bool   TRUE while held in FAULT
//   32.3   EStop_Active      Bool   TRUE when E-Stop is pressed
//   34.0   Alarm_Code        Int    0 none, 1 E-Stop, 2 Abort
//   36.0   Cmd_Start         Bool   Remote start   (written by gateway)
//   36.1   Cmd_Stop          Bool   Remote stop
//   36.2   Cmd_Abort         Bool   Remote abort
//   36.3   Cmd_Reset         Bool   Remote fault reset
//   36.4   Cmd_Recipe1       Bool   Remote select recipe 1
//   36.5   Cmd_Recipe2       Bool   Remote select recipe 2
//   36.6   Cmd_Recipe3       Bool   Remote select recipe 3
//
//  TOTAL SIZE = 38 bytes  (gateway reads 38 bytes from DB1)
//
//  Why the offsets line up: the four status bools sit in byte 32, then
//  the Int "Alarm_Code" forces alignment to the next even byte (34),
//  which leaves the seven command bools alone in byte 36. That keeps
//  the command byte isolated, so the gateway can pulse a command
//  without disturbing any status bit.
// ------------------------------------------------------------

DATA_BLOCK "BatchData"
{ S7_Optimized_Access := 'FALSE' }   // <-- MUST be FALSE for snap7
VERSION : 0.1
   VAR
      State : Int := 0;
      ActiveRecipe : Int := 0;
      Temp_SP : Real := 0.0;
      Temp_PV : Real := 25.0;          // start at 25 C ambient
      Level_SP : Real := 0.0;
      Level_PV : Real := 0.0;
      Heater_Output : Real := 0.0;
      MixTime_SP : Int := 0;
      MixTime_Elapsed : Int := 0;
      BatchCount : DInt := 0;
      BatchRunning : Bool := FALSE;
      BatchComplete : Bool := FALSE;
      Fault : Bool := FALSE;
      EStop_Active : Bool := FALSE;
      Alarm_Code : Int := 0;
      Cmd_Start : Bool := FALSE;
      Cmd_Stop : Bool := FALSE;
      Cmd_Abort : Bool := FALSE;
      Cmd_Reset : Bool := FALSE;
      Cmd_Recipe1 : Bool := FALSE;
      Cmd_Recipe2 : Bool := FALSE;
      Cmd_Recipe3 : Bool := FALSE;
   END_VAR
BEGIN
END_DATA_BLOCK


// ============================================================
// FB1 : "BatchSequence"  (Structured Text / SCL)
// ------------------------------------------------------------
// The ISA-88 style batch state machine, written as a CASE statement.
// It loads the selected recipe's setpoints, drives the valves /
// agitator / heater-enable by phase, times the mix with a TON, and
// advances phase-by-phase. E-Stop and Abort override everything and
// drive all actuators to a safe state.
//
// Call this once per scan from OB1 (Main). PID temperature control
// runs separately in OB30 (the cyclic interrupt).
//
// Phases:  0 IDLE -> 10 FILL -> 20 HEAT -> 30 MIX -> 40 DRAIN
//          -> 50 COMPLETE -> 0 IDLE      (90 = FAULT / HELD)
// ============================================================

FUNCTION_BLOCK "BatchSequence"
{ S7_Optimized_Access := 'TRUE' }
VERSION : 0.1

   VAR_INPUT
      StartReq : Bool;      // latched run request from OB1 (Run_Latch, M20.0)
      EStopOK : Bool;       // E_Stop input I0.2 (TRUE = healthy, NC wiring)
      Clock1Hz : Bool;      // 1 Hz clock bit M10.5 (for the elapsed-mix counter)
   END_VAR

   VAR
      StartTrig : R_TRIG;   // rising edge of the run request
      ClockTrig : R_TRIG;   // rising edge of the 1 Hz clock
      MixTimer : TON_TIME;  // mix-time on-delay timer
      MixPT : Time := T#0S; // mix-time preset (loaded from the recipe)
   END_VAR

   VAR_TEMP
      AbortNow : Bool;      // physical Abort button OR remote Cmd_Abort
      StartEdge : Bool;     // one-scan pulse when Start is pressed
      Inlet : Bool;         // local actuator decisions for this scan
      Outlet : Bool;
      Agit : Bool;
      HeaterEn : Bool;
   END_VAR

BEGIN

   // ---- edge detection ----
   #StartTrig(CLK := #StartReq);
   #StartEdge := #StartTrig.Q;
   #ClockTrig(CLK := #Clock1Hz);

   // ---- combined abort: physical button OR remote command ----
   #AbortNow := "Abort_Button" OR "BatchData".Cmd_Abort;

   // ---- mix timer: counts only while we are in the MIXING phase ----
   #MixTimer(IN := ("BatchData".State = 30), PT := #MixPT);

   // ---- default every actuator OFF; each phase turns on what it needs ----
   #Inlet := FALSE;
   #Outlet := FALSE;
   #Agit := FALSE;
   #HeaterEn := FALSE;

   // ---- SAFETY OVERRIDES (highest priority, evaluated before the CASE) ----
   // E-Stop is wired normally closed, so EStopOK is TRUE when healthy.
   "BatchData".EStop_Active := NOT #EStopOK;
   IF NOT #EStopOK THEN
      "BatchData".State := 90;            // FAULT / HELD
      "BatchData".Alarm_Code := 1;        // E-Stop
      "Run_Latch" := FALSE;               // break the start seal
   ELSIF #AbortNow AND ("BatchData".State <> 0) AND ("BatchData".State <> 90) THEN
      "BatchData".State := 90;
      "BatchData".Alarm_Code := 2;        // operator abort
      "Run_Latch" := FALSE;
   END_IF;

   // ---- THE STATE MACHINE ----
   CASE "BatchData".State OF

      0:  // IDLE - all actuators off; keep the selected recipe's setpoints on show
         CASE "BatchData".ActiveRecipe OF
            1:  // Product A
               "BatchData".Temp_SP := 60.0;
               "BatchData".Level_SP := 80.0;
               "BatchData".MixTime_SP := 10;
               #MixPT := T#10S;
            2:  // Product B
               "BatchData".Temp_SP := 75.0;
               "BatchData".Level_SP := 90.0;
               "BatchData".MixTime_SP := 20;
               #MixPT := T#20S;
            3:  // Product C
               "BatchData".Temp_SP := 50.0;
               "BatchData".Level_SP := 70.0;
               "BatchData".MixTime_SP := 15;
               #MixPT := T#15S;
            ELSE
               "BatchData".Temp_SP := 0.0;
               "BatchData".Level_SP := 0.0;
               "BatchData".MixTime_SP := 0;
               #MixPT := T#0S;
         END_CASE;

         "BatchData".Fault := FALSE;

         // Start the batch on a fresh Start press, with a valid recipe and a healthy E-Stop.
         IF #StartEdge
            AND ("BatchData".ActiveRecipe >= 1)
            AND ("BatchData".ActiveRecipe <= 3)
            AND #EStopOK THEN
            "BatchData".BatchComplete := FALSE;
            "BatchData".MixTime_Elapsed := 0;
            "BatchData".State := 10;       // -> FILLING
         END_IF;

      10:  // FILLING - inlet valve open until the level reaches the recipe target
         #Inlet := TRUE;
         IF "BatchData".Level_PV >= "BatchData".Level_SP THEN
            "BatchData".State := 20;       // -> HEATING
         END_IF;

      20:  // HEATING - enable the heater; the PID (OB30) drives temperature to setpoint
         #HeaterEn := TRUE;
         IF "BatchData".Temp_PV >= ("BatchData".Temp_SP - 1.0) THEN
            "BatchData".State := 30;       // -> MIXING (within 1 C of setpoint)
         END_IF;

      30:  // MIXING - run the agitator for the recipe time; hold temperature with the heater
         #Agit := TRUE;
         #HeaterEn := TRUE;
         IF #ClockTrig.Q THEN
            "BatchData".MixTime_Elapsed := "BatchData".MixTime_Elapsed + 1;
         END_IF;
         IF #MixTimer.Q THEN
            "BatchData".State := 40;       // -> DRAINING
         END_IF;

      40:  // DRAINING - outlet valve open until the tank is empty
         #Outlet := TRUE;
         IF "BatchData".Level_PV <= 2.0 THEN
            "BatchData".State := 50;       // -> COMPLETE
         END_IF;

      50:  // COMPLETE - count the batch, then return to idle
         "BatchData".BatchCount := "BatchData".BatchCount + 1;
         "BatchData".BatchComplete := TRUE;
         "Run_Latch" := FALSE;            // require a fresh Start for the next batch
         "BatchData".State := 0;          // -> IDLE

      90:  // FAULT / HELD - all actuators safe; wait for a reset
         "BatchData".Fault := TRUE;
         IF #EStopOK AND NOT #AbortNow AND "BatchData".Cmd_Reset THEN
            "BatchData".Alarm_Code := 0;
