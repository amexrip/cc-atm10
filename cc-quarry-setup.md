# ATM10 wireless quarry system

This system has four programs:

- `cc-mining-station.lua` plus `cc-mining-station-core.lua`: command station.
- `cc-mining-turtle.lua` plus `cc-mining-turtle-core.lua`: 32x32 layered quarry.
- `cc-mining-sorter.lua`: sorter.
- `cc-lava-turtle.lua`: lava-bucket refill turtle.

The two wrapper files load their matching `-core.lua` file. Transfer both files
to that computer/turtle and use the wrapper name to start the program.

## Station placement

Use one connected 3x5 advanced monitor, the speaker on the station's left,
the chatbox on its right, and a wireless modem on the back. Peripheral names
are discovered automatically. Start this station before any turtle.

The station says that it is ready to pair in chat and announces each turtle
when it connects. The station monitor shows three colored panels, fuel bars,
tasks, errors, miner position, mining totals, bucket counts, top blocks, and a
small pickaxe animation.

The supplied MP3 cannot be played directly by a CC:Tweaked speaker. Convert
`the-bluetooth-device-is-ready-to-pair.mp3` to DFPWM, name it `startup.dfpwm`,
and put it on the station computer. Without that file, the station plays a
built-in startup tone.

## Mining turtle placement

Start the mining turtle at one corner, facing into the quarry:

```text
                 quarry
                   ^
        lava chest | turtle | unsorted chest
             (left)          (behind)
```

The miner descends its first column to the lowest breakable layer, clears the
32x32 layer in a serpentine path, moves up one layer, and repeats until the
surface layer is complete. This clears every cell in the quarry area rather
than only making tunnels.

The miner returns to its start point when its inventory is full, drops into
the unsorted chest behind it, then takes filled lava buckets from the left
chest. It converts each bucket into fuel and returns every empty bucket to the
fuel chest. Below 2,000 fuel it services itself and will not resume until it
reaches 50,000 fuel.

The miner tracks position relative to its starting point. Do not move or
rotate it while it is running. Keep enough fuel buckets available to cover
the trip home; if it cannot return, it reports an error and stops.

## Sorter placement

The sorter starts directly above destination chest 1, facing the unsorted
input chest. Destination chests extend to its right:

```text
             unsorted input chest
                      ^
                      |
       chest 1  chest 2  chest 3 ... chest 8
          ^       right from chest 1
        sorter
```

All eight destinations may be Sophisticated Storage Netherite chests. The
sorter returns to chest 1 to take one stack, then travels along the row and
drops the stack down into the selected chest. Set `FUEL_CHEST_SIDE` near the
top of the sorter script if its lava-bucket chest is not on the turtle's
left.

Categories are:

1. Grass and dirt.
2. Cobblestone, cobbled deepslate, and names containing `kivi`.
3. Andesite, diorite, granite, and gravel.
4. Netherite, ancient debris, and soul sand.
5. End stone.
6. Explicitly known unsmeltable ores.
7. Coal and names containing `coal`.
8. Explicitly known smeltable ores.

The sorter never guesses an unknown ore. It leaves it in the unsorted chest
and asks the station to ask the player:

```text
Can I smelt <ore name>? Y/N
```

Reply with an unambiguous `Y` or `N`. A yes is persisted as smeltable and a
no is persisted as unsmeltable. No response after five minutes is treated as
unsmeltable. Set `PLAYER_NAME` in the station core if replies must be limited
to one player.

## Lava turtle placement

Start the lava turtle facing the Mekanism fluid tank, with the bucket chest
directly below it. It uses `turtle.place()` against the tank, which is the
CC:Tweaked right-click/use action for filling an empty bucket. It does not use
`turtle.dig()`, so it will not break the tank.

The turtle takes empty buckets from the chest below, fills them one at a time,
and returns filled lava buckets to that same chest for the miner and sorter.
This stationary turtle does not consume the filled buckets for fuel. Set
`BUCKET_CHEST_SIDE` in the lava script if your chest is not below the turtle.

## Installation

On the station, transfer both station files:

```text
pastebin get <station-wrapper-paste> mining_station
pastebin get <station-core-paste> cc-mining-station-core.lua
mining_station
```

On the miner, transfer both miner files:

```text
pastebin get <miner-wrapper-paste> mining_turtle
pastebin get <miner-core-paste> cc-mining-turtle-core.lua
mining_turtle
```

Transfer the sorter and lava programs under their matching names and run them
after the station:

```text
sorter
lava_turtle
```

Pastebin IDs are intentionally omitted here because they depend on where you
choose to upload these local files. `BASE_ID` can be set in each turtle to
the station computer ID to skip pairing discovery.

## Verification sequence

1. Run the station and confirm modem, monitor, speaker, and chatbox.
2. Run each turtle one at a time and confirm its role and ID on the monitor.
3. Test the lava turtle with one empty bucket and a drawer containing lava.
4. Test miner fuel conversion with one filled lava bucket, then verify the
   empty bucket returns to the fuel chest.
5. Put one known item in the unsorted chest and verify its destination.
6. Test an unknown ore and answer `Y`; verify it reaches chest 8.
7. Restart the station and verify the learned ore decision remains stored.
8. Test a full destination chest and a full unsorted chest before starting a
   long quarry.
