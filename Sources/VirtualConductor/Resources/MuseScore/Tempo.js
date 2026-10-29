// Shared by the live companion and the isolated preview export.
function kind(item, name) { return item && (item.type === name || item.name === name); }
function signature(score) {
    var rows = [score.nstaves, score.nmeasures];
    for (var s = score.firstSegment(); s; s = s.next) {
        for (var track = 0; track < score.ntracks; ++track) {
            var e = s.elementAt(track);
            if (!e || e.name === "TimeTickAnchor") continue;
            var notes = [];
            if (e.notes) for (var n = 0; n < e.notes.length; ++n) notes.push(e.notes[n].pitch);
            rows.push([s.tick, track, e.name, notes, e.duration ? e.duration.ticks : 0]);
        }
        for (var a = 0; a < s.annotations.length; ++a) {
            var t = s.annotations[a];
            rows.push([s.tick, t.name, t.text || '', t.tempo || 0]);
        }
    }
    for (var i = 0; i < score.spanners.length; ++i) {
        var sp = score.spanners[i]; rows.push([sp.name, sp.spannerTick.ticks, sp.spannerTicks.ticks, sp.tempoChangeFactor || 0]);
    }
    return JSON.stringify(rows);
}
function apply(api, score, request) {
    for (var measure = score.firstMeasure; measure; measure = measure.nextMeasure) {
        if (measure.repeatStart || measure.repeatEnd || measure.repeatJump || measure.irregular)
            throw new Error('Keeping timing currently needs a score without repeats, jumps, or pickup bars. Rehearsal playback still works.');
    }
    if (!request.tempos || request.tempos.length < 1) throw new Error('No timing to apply.');
    var remove = [];
    var start = request.start * 480, end = request.end * 480;
    // Crossing gradual changes need splitting to preserve the music outside the passage.
    // Until implemented, report this specific unsupported case instead of changing other bars.
    for (var i = 0; i < score.spanners.length; ++i) {
        var sp = score.spanners[i];
        if (kind(sp, 'GRADUAL_TEMPO_CHANGE') || sp.name === 'GradualTempoChange') {
            var first = sp.spannerTick.ticks, last = first + sp.spannerTicks.ticks;
            if (!isFinite(first) || !isFinite(last)) throw new Error('This score has a gradual tempo change that cannot yet be mapped.');
            if (first < end && last > start) {
                if (first < start || last > end) throw new Error('Choose a passage that includes the entire ritardando or accelerando.');
                remove.push(sp);
            }
        }
    }
    for (var s = score.firstSegment(); s; s = s.next) {
        if (s.tick < start || s.tick > end) continue;
        for (var a = 0; a < s.annotations.length; ++a) {
            var t = s.annotations[a];
            if (kind(t, 'TEMPO_TEXT') || t.name === 'Tempo') remove.push(t);
        }
    }
    score.startCmd('Keep Virtual Conductor interpretation');
    try {
        for (var r = 0; r < remove.length; ++r) api.removeElement(remove[r]);
        var c = score.newCursor(); c.track = 0; c.filter = api.Segment.TimeTick;
        for (var j = 0; j < request.tempos.length; ++j) {
            var point = request.tempos[j];
            if (!isFinite(point.quarter) || !isFinite(point.bpm) || point.bpm < 10 || point.bpm > 600) throw new Error('Timing is outside the supported tempo range.');
            c.rewindToFraction(api.fraction(Math.round(point.quarter * 480), 1920));
            if (Math.abs(c.tick - point.quarter * 480) > 1) throw new Error('Could not locate a requested beat.');
            var id = api.Element.TEMPO_TEXT;
            // 4.7.6 macros expose names, while newElement still takes numeric enum values.
            if (typeof id === 'string') id = Object.keys(api.Element).indexOf('TEMPO_TEXT') + 1;
            var tempo = api.newElement(id);
            if (!tempo || tempo.name !== 'Tempo') throw new Error('MuseScore tempo API changed; no changes were kept.');
            tempo.tempo = point.bpm / 60;
            tempo.tempoFollowText = true;
            tempo.text = '<sym>metNoteQuarterUp</sym> = ' + point.bpm;
            c.add(tempo);
        }
        score.endCmd();
    } catch (error) { score.endCmd(true); throw error; }
}
