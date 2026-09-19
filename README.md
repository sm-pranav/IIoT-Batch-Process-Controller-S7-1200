# Automated Batch Process Controller (PID + ISA-88)

A simulated process-control system built on a Siemens S7-1200. The PLC runs a heated mixing tank through a recipe: it fills to a level, holds a temperature with a PID loop, mixes for a set time, then drains and counts the batch. A Python gateway reads the PLC over the S7 protocol and streams live values to a browser dashboard that can also send commands back.

## Overview

Batch processes in pharma, food, and specialty chemicals make a product one lot at a time by following a recipe: reach a level, hold a temperature for a time, then move on to the next step. I wanted to build that whole loop the way it is done on the plant floor, but without buying hardware, so the control logic is genuine S7-1200 code running in Siemens PLCSIM.

A simulator has no physical process behind it, so the temperature and level would never move on their own. To get around that, the PLC program includes a small first-order tank model that runs in the same fast interrupt as the controller. That gives the PID a live process to push against, and it is the reason you can watch a real closed loop settle inside the simulator. Around the PLC sits a two-way data path: an edge gateway written in Python and a single-file web dashboard.

The two things this project is really about are PID closed-loop temperature control and a recipe-driven step sequence in the ISA-88 style.

