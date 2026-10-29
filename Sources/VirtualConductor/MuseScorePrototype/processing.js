function main() {
 const e = api.engraving;
 const s = e.curScore;
 api.log.info("VC_PROOF enums " + e.Element.TEMPO_TEXT + " / " + e.Segment.TimeTick);
 api.log.info("VC_PROOF start " + s.scoreName);
 s.startCmd("PROTOTYPE apply tempo");
 const c = s.newCursor(); c.track = 0;
 c.filter = e.Segment.TimeTick;
 const beats = [0, 1, 5, 8]; const bpms = [120, 60, 90, 120];
 for (let i = 0; i < beats.length; ++i) {
   c.rewindToFraction(e.fraction(beats[i], 4));
   api.log.info("VC_PROOF cursor " + beats[i] + " tick " + c.tick);
   // Installed 4.7.6 exposes string enums to macros but newElement takes an int.
   // EXPERIMENT ONLY: enum ordering is not a supported contract; validate type.
   const t = e.newElement(Object.keys(e.Element).indexOf("TEMPO_TEXT") + 1);
   api.log.info("VC_PROOF created " + t.name + " type " + t.type);
   if (t.name !== "Tempo") throw new Error("Unexpected native element: " + t.name);
   t.tempo = bpms[i] / 60; t.tempoFollowText = true;
   t.text = '<sym>metNoteQuarterUp</sym> = ' + bpms[i];
   c.add(t);
 }
 s.endCmd();
 api.log.info("VC_PROOF done");
}
