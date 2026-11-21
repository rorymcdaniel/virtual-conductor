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
function newTempo(api, cursor, quarter, bpm, visible) {
    cursor.rewindToFraction(api.fraction(Math.round(quarter * 480), 1920));
    var distance = visible ? Math.abs(cursor.tick - quarter * 480) : Math.abs(cursor.tick - Math.round(quarter * 480));
    if (distance > (visible ? 1 : 0)) throw new Error('Could not locate a requested beat.');
    var id = api.Element.TEMPO_TEXT;
    // Macros expose names, while newElement still takes numeric enum values.
    if (typeof id === 'string') id = Object.keys(api.Element).indexOf('TEMPO_TEXT') + 1;
    var tempo = api.newElement(id);
    if (!tempo || tempo.name !== 'Tempo') throw new Error('MuseScore tempo API changed.');
    tempo.tempo = bpm / 60;
    tempo.tempoFollowText = true;
    tempo.text = '<sym>metNoteQuarterUp</sym> = ' + bpm;
    if (!visible) tempo.visible = false;
    cursor.add(tempo);
}

function selectedLocation(score, segment) {
    if (!segment) return null;
    var measure = score.firstMeasure;
    while (measure.nextMeasure && measure.nextMeasure.tick.ticks <= segment.tick)
        measure = measure.nextMeasure;
    return {measure: measure.no + measure.noOffset + 1, tick: segment.tick,
            quarterBeat: 1 + (segment.tick - measure.tick.ticks) / 480};
}

function documentInfo(score) {
    var selection = score.selection;
    var selected = [];
    if (selection.isRange) {
        selected = [selectedLocation(score, selection.startSegment),
                    selectedLocation(score, selection.endSegment)];
    } else {
        for (var i = 0; i < selection.elements.length; ++i) {
            var element = selection.elements[i], name = element.name;
            while (element && element.name !== 'Segment') element = element.parent;
            selected.push({element: name, location: selectedLocation(score, element)});
        }
    }
    return {name: score.scoreName, staves: score.nstaves, measures: score.nmeasures,
            selection: {kind: selection.isRange ? 'range' : 'elements', locations: selected}};
}

function playbackPlan(api, score, request) {
    // The MIDI check uses written quarters and requires a linear timeline.
    var measures = {}, endQuarter = 0;
    for (var measure = score.firstMeasure; measure; measure = measure.nextMeasure) {
        var meter = measure.timesigNominal;
        if (measure.repeatStart || measure.repeatEnd || measure.repeatJump || measure.irregular ||
            measure.ticks.ticks !== 1920 || !meter || meter.numerator !== 4 || meter.denominator !== 4)
            throw new Error('Playback tempo editing currently requires straight 4/4 without repeats, jumps, or pickups.');
        // MuseScore's API returns the internal zero-based number.
        var number = measure.no + measure.noOffset + 1;
        if (measures[number] !== undefined)
            throw new Error('The score has ambiguous measure numbers.');
        measures[number] = measure.tick.ticks / 480;
        endQuarter = measures[number] + 4;
    }
    if (!request.points || !request.points.length) throw new Error('Provide at least one tempo.');
    function quarter(position, allowEnd) {
        var start = measures[position.measure], beat = position.beat;
        if (allowEnd && position.measure === number + 1 && beat === 1) return endQuarter;
        if (start === undefined || !Number.isFinite(beat) || beat < 1 || beat >= 5 ||
            Math.abs(beat * 480 - Math.round(beat * 480)) > 1e-7)
            throw new Error('Choose a valid measure and quarter-note beat on the score grid.');
        return start + Math.round((beat - 1) * 480) / 480;
    }
    var end = quarter(request.end, true);
    var points = request.points.map(function (point) {
        if (!Number.isFinite(point.bpm) || point.bpm < 10 || point.bpm > 600)
            throw new Error('Playback tempos must be between 10 and 600 BPM.');
        return {quarter: quarter(point, false), bpm: point.bpm};
    });
    for (var i = 0; i < points.length; ++i) {
        if (points[i].quarter >= end || (i && points[i].quarter <= points[i - 1].quarter))
            throw new Error('Enter tempos in strictly increasing score order before the end.');
    }
    var pauses = [];
    for (var s = score.firstSegment(); s; s = s.next) {
        if (typeof api.Segment.Breath === 'number' && s.segmentType !== api.Segment.Breath) continue;
        for (var track = 0; track < score.ntracks; ++track) {
            var breath = s.elementAt(track);
            if (kind(breath, 'Breath') && breath.pause > 0) {
                pauses.push(s.tick / 480);
                break;
            }
        }
    }
    return {points: points, end: end, scoreEnd: endQuarter, pauses: pauses};
}

function applyPlayback(api, score, request) {
    var plan = playbackPlan(api, score, request);
    var points = plan.points, start = points[0].quarter, end = plan.end;
    var spans = [], markings = [], existing = {};
    for (var i = 0; i < score.spanners.length; ++i) {
        var span = score.spanners[i];
        if (!kind(span, 'GRADUAL_TEMPO_CHANGE') && span.name !== 'GradualTempoChange') continue;
        var first = span.spannerTick.ticks / 480, last = first + span.spannerTicks.ticks / 480;
        if (!Number.isFinite(first) || !Number.isFinite(last))
            throw new Error('A gradual tempo change could not be located.');
        if (first >= end || last <= start) continue;
        if (first < start || last > end)
            throw new Error('The edit range must include the entire gradual tempo change at quarter ' + first + '.');
        spans.push(span);
    }
    var current = 0;
    for (var segment = score.firstSegment(); segment; segment = segment.next) {
        var q = segment.tick / 480;
        if (q < start || q > end) continue;
        while (current + 1 < points.length && points[current + 1].quarter <= q) ++current;
        for (var a = 0; a < segment.annotations.length; ++a) {
            var marking = segment.annotations[a];
            if (!kind(marking, 'TEMPO_TEXT') && marking.name !== 'Tempo') continue;
            existing[q] = true;
            if (q < end && Math.abs(marking.tempo * 60 - points[current].bpm) > 0.00001)
                markings.push({element: marking, bpm: points[current].bpm});
        }
    }
    var restore = request.restoreBpm;
    if (end < plan.scoreEnd && (!Number.isFinite(restore) || restore <= 0))
        throw new Error('The original playback tempo at the end of the range is required.');
    score.startCmd('Edit playback tempos');
    try {
        for (var j = 0; j < spans.length; ++j) spans[j].tempoChangeFactor = 1;
        for (var k = 0; k < markings.length; ++k) {
            markings[k].element.tempoFollowText = false;
            markings[k].element.tempo = markings[k].bpm / 60;
        }
        var cursor = score.newCursor();
        cursor.track = 0;
        cursor.filter = api.Segment.TimeTick;
        for (var p = 0; p < points.length; ++p) {
            if (!existing[points[p].quarter]) newTempo(api, cursor, points[p].quarter, points[p].bpm, false);
        }
        if (end < plan.scoreEnd && !existing[end] && Math.abs(restore - points[points.length - 1].bpm) > 0.001)
            newTempo(api, cursor, end, restore, false);
        score.endCmd();
    } catch (error) { score.endCmd(true); throw error; }
    return plan;
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
            newTempo(api, c, point.quarter, point.bpm, true);
        }
        score.endCmd();
    } catch (error) { score.endCmd(true); throw error; }
}
