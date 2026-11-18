# Flip-Flop

A wobbly, physics-based online co-op game made with **Godot 4.4**. You control a floppy little
person by moving each hand and each foot separately. Walking is hard. Carrying things is harder.
That's the point.

This first version is a **test room**: walk around, pick things up, knock over towers, hang off
a bar, and drop things into the basket.

## Controls (controller required)

| Input | Action |
|---|---|
| Left stick | Move left hand |
| Right stick | Move right hand |
| ↳ push forward / pull back | reach out / reach down to the floor (you squat and bend over) |
| L1 / R1 (hold) | Grab with left / right hand. Whatever the hand touches sticks to it: props, walls, the floor, other players |
| L2 + left stick | Lift and move left foot |
| R2 + right stick | Lift and move right foot |
| D-pad left / right | Rotate the camera |
| Back / Select | Respawn |
| Start | Show / hide the controls help |
| Esc (keyboard) | Leave to the main menu |

**To walk:** hold L2, push the left stick forward, let go of L2. Then hold R2, push the right
stick forward, let go of R2. Repeat. Your body shuffles over to sit between your feet.

Sticks are camera-relative: "forward" means away from the camera.

There's a keyboard fallback for debugging only (WASD / IJKL hands, Q / U grab, E / O feet,
Z / X camera, R respawn, H help).

## Running it

1. Install [Godot 4.4](https://godotengine.org/download) (the standard build, not .NET).
2. Open Godot, choose **Import**, and select this folder's `project.godot`.
3. Press **F5** to play.

The project uses Godot's built-in **Jolt** physics engine (`Project Settings → Physics → 3D`)
at 120 physics ticks per second, which keeps the springy body stable.

## Playing online

- One person picks **Host Online Game**. The HUD shows their local IP address.
- Everyone else types that IP into the box and picks **Join**. Up to 4 players.
- Default port is **7777 (UDP)**. On the same Wi-Fi/LAN this just works. Over the internet, the
  host needs to forward UDP 7777 on their router (or use a VPN like Tailscale/ZeroTier and
  share that IP instead).

Command-line shortcuts (handy for testing two copies on one PC):

```bash
godot --path . -- --host
```

```bash
godot --path . -- --join=127.0.0.1
```

```bash
godot --path . -- --solo
```

### How the networking works

The host runs **all** the physics: every player body and every prop. Clients only send their
controller state (about 60 times a second) and draw what the host sends back (positions of every
body about 30 times a second, blended smoothly). That keeps everyone's wobbly physics in
agreement, which matters when two people are carrying the same crate. The downside is that
clients feel their own input with a bit of delay. That's acceptable for a floppy co-op game, and
client-side prediction can come later.

## How the character works

The character is five rigid bodies: a torso (with the head), two hands and two feet. They are
held together by **springs, not joints**, which is where the wobble comes from:

- **Hands** are pulled toward a target set by the stick. A soft "bone" constraint stops them
  from getting further than arm's length from the shoulder. Reaching also yanks the torso a bit.
- **Feet** that touch the ground get *planted* and stay put. Lift one with L2/R2 and it follows
  the stick. Put it down and it plants in the new spot.
- **Torso**: the legs push it up to standing height above the planted feet and pull it sideways
  to sit between them. With no feet planted (both lifted, or knocked off your feet) the support
  disappears and you flop over.
- A weak "stay upright" twist, plus a bit of deliberate drunken sway, keeps it standing, barely.
- **Grabbing** creates a pin joint between the hand and whatever it touches, released when you
  let go of the button.

All the tuning numbers live at the top of `scripts/player.gd` (`SUPPORT_K`, `UPRIGHT_K`,
`HAND_K`, `WOBBLE` and so on). Lower stiffness = wobblier.

## Project layout

```
project.godot          Engine settings (Jolt physics, 120 Hz)
scenes/main.tscn       Root scene (just the Main node)
scripts/main.gd        Menu, networking (ENet), camera, HUD
scripts/player.gd      The wobbly character: physics, grabbing, visuals, snapshots
scripts/world.gd       The test room and its props, built in code
scripts/input_setup.gd Controller mapping
```

## The test room

- A pile of crates and a block tower to knock over
- A table with balls and rubber ducks
- A big beach ball, a plank and some traffic cones
- A ramp and some stairs to practise walking on
- A monkey bar to hang from (grab with both hands, lift both feet)
- A **TEAM LIFT** crate that's too heavy for one person
- A basket with a counter: drop things in it
