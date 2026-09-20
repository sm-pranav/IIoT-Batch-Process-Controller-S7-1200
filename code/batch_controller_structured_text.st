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
