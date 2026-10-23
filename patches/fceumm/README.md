# FCEUmm patches

TinyNES builds libretro FCEUmm at the commit `tools/fetch_fceumm.sh` pins,
with the patches in this directory applied in name order. Most fix a
behaviour that 100th Coin's AccuracyCoin test cartridge checks, measured with
`tools/accuracycoin.py` before and after; 0008 is a speed fix and 0009 a save
state fix, each header saying what it was measured with. Every one is checked
against the benchmark's checksums and frame time so a fix that changes a game,
or costs the A25 time, is seen.

**Licence.** These patches change FCEUmm, which is GPL-2.0 (most of its files
GPL-2.0-or-later, `third_party/fceumm/Copying`), and they are GPL-2.0-or-later
too, unlike the rest of this repository, which is MIT. They are kept here so
anyone, FCEUmm's own developers included, can take them.

Where a patch follows the behaviour of 100th Coin's TriCNES emulator
(MIT, https://github.com/100thCoin/TriCNES) or the explanations in
AccuracyCoin's source (MIT, https://github.com/100thCoin/AccuracyCoin), its
header says so.

To make one: edit `third_party/fceumm`, then
`tools/fceumm_patch.sh <short-name> "<subject>"`, and fill in its header.
