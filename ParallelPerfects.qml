import QtQuick 2.0
import QtQuick.Dialogs 1.1
import MuseScore 3.0

MuseScore {
    menuPath: "Plugins.Proof Reading.Advanced Parallel Perfect Detection"
    description: "Weeds out parallel perfects."
    version: "1.0"

    //********************************************************
    // Missing language features & other generic functionality
    //********************************************************

    // Count the amount of items within an object or array
    // .length is not to be trusted when you're using arrays more like sets
    function count(arr)
    {
        var total = 0;
        for(var p in arr)
        {
            var x = arr[p];
            if(arr.hasOwnProperty(p) && x !== undefined && x !== null && typeof x != "function")
                total += 1;
        }
        return total;
    }

    // QT does not print objects in full which is tiresome when logging is the only debug facility
    function print_json(o, depth)
    {
        if(depth === undefined) depth = 5;
        if(depth === 0) return "...";
        var out = "";
        if(o === undefined || o === null) out += o;
        else if(o.length !== undefined)
        {
            out += "[";
            for(var i = 0; i < o.length; ++i)
                out += print_json(o[i], depth - 1) + (i == o.length - 1 ? "" : ", ");
            out += "]";
        }
        else if(typeof o == "object")
        {
            out += "{";
            for(var k in o)
                if(o[k] !== undefined && o.hasOwnProperty(k) && typeof o[k] != "function")
                    out += "\"" + k + "\": " + print_json(o[k], depth - 1) + ",";
            out = out.substr(0, out.length-1) + "}";
        }
        else if(typeof o == "function") out += "\"[function]\"";
        else if(typeof o == "string")   out += "\"" + o + "\"";
        else out += o;
        return out;
    }

    function polyfill()
    {
        // Is e present within a given array?
        Array.prototype.includes = function (e) { return this.filter(function(x) { return x == e; }).length > 0; };
        Array.prototype.unique = function(f)
        {
            var out = []
            for(var i = 0; i < this.length; ++i)
            {
                var j = this.indexOf(this[i]);
                if(j >= i) out.push(this[i]);
            }
            return out;
        };
        
        // A 'true' mod that is, mod(-1, 7) == 6, while -1 % 7 == -1
        Math.mod = function(a, b) { return a % b + b * +(a < 0); };

        // f should return -1 if we should look to the left 1 otherwise, 0 exits with that value immediately
        // search_type: 0 = only accept f(x) == 0 matches, -1 = take left value on no exact match, 1 = take right value on no exact match
        // Can be used to implement exact, left of & right of searches in sorted lists with arbitrary objects
        Array.prototype.binary_search = function(f, search_type, lo, hi)
        {
            for(var i = 0; i < this.length; ++i)
            {
                var fr = f(this[i]);
                if(fr === 0) return this[i];
                if(fr < 0)
                {
                    if(search_type === -1) return this[i-1];
                    if(search_type === 1) return this[i];
                    return undefined;
                }
            }

            if(search_type === -1 && this.length) return this[this.length-1];
            return undefined;
        };
    }

    //*********************************************
    // Loading music into more convenient structure
    //*********************************************
    function read_voice(cursor, end)
    {
        var read_chordrest = function(chordrest, start, onbeat, measure)
        {
            // Some basic utility/math functions that are missing
            var tpc_to_accidentals = function(tpc) { return Math.floor((tpc - 14 + 1) / 7); };
            var chromatic_to_diatonic = function(c, a) { return Math.floor((c - a) / 2) + Math.floor((c - a) / 12) + (+(Math.mod((c - a), 12) > 4)); };

            var note = chordrest.notes ? chordrest.notes[0] : (chordrest.pitch ? chordrest : null);
            return {
                chroma_pitch: note ? note.pitch : null,
                pitch: note ? chromatic_to_diatonic(note.pitch, tpc_to_accidentals(note.tpc1)) : null,
                start: start,
                duration: chordrest.duration.ticks,
                end: start + chordrest.duration.ticks,
                prev: null,
                next: null,
                onbeat: onbeat,
                measure: measure,
                in_dim_chord: false
            };
        };

        if(!cursor.measure)
            return {id:Math.random().toString(), notes: []};

        var voice = [];
        var prev_ticks = cursor.tick;
        var measure_offset = 0;
        var current_measure_number = 1;
        var current_measure_duration = 0;
        var current_measure_length = cursor.measure.timesigActual.ticks;
        var previous_was_rest = true;

        for(var prev_node = null; !cursor.eos && cursor.tick <= end; cursor.next())
        {
            if(!cursor.element) break;

            // .duration.ticks does not work for tuplets and I can't actually get the global ticks...
            if(!previous_was_rest)
            {
                voice[voice.length-1].duration = cursor.tick - prev_ticks;
                voice[voice.length-1].end = cursor.tick;
            }

            var beat = (current_measure_length  / cursor.measure.timesigActual.numerator);
            if(cursor.measure.timesigActual.denominator % 2 == 0)
                beat *= 2;

            var node = read_chordrest(cursor.element, cursor.tick, (cursor.tick - measure_offset) % beat == 0, current_measure_number);
            if(node.pitch)
            {
                if(prev_node) prev_node.next = node;
                node.prev = prev_node;
                prev_node = node;
                previous_was_rest = false;
                voice.push(node);
            }
            else previous_was_rest = true;

            current_measure_duration += cursor.tick - prev_ticks;
            while(current_measure_duration >= current_measure_length)
            {
                current_measure_number += 1;
                measure_offset += current_measure_length;
                current_measure_duration -= current_measure_length;
                current_measure_length = cursor.measure.timesigActual.ticks;
            }
            prev_ticks = cursor.tick;
        }
        return {id:Math.random().toString(), notes: voice};
    }

    function read_all_voices(score, merge_notes)
    {
        if(merge_notes === undefined) merge_notes = true;
        var voices = [];
        for(var i = 0; i < score.nstaves*4; ++i)
        {
            var cursor = score.newCursor();
            var end = 0xFFFFFFF;
            cursor.rewind(2);
            if(cursor.segment) end = cursor.tick;
                cursor.rewind(cursor.segment ? 1 : 0);

            cursor.track = i;
            if(merge_notes)
                voices.push(merge_repeated_notes(read_voice(cursor, end)));
            else
                voices.push(read_voice(cursor, end));

            print(voices[i].notes.length);
        }
        return voices;
    }

    function merge_repeated_notes(a)
    {
        var voice = a.notes.length ? [a.notes[0]] : [];

        for(var i = 1; i < a.notes.length; ++i)
        {
            if(a.notes[i-1].chroma_pitch === a.notes[i].chroma_pitch && a.notes[i-1].end === a.notes[i].start)
            {
                voice[voice.length-1].end += a.notes[i].duration;
                voice[voice.length-1].duration += a.notes[i].duration;
            }
            else
                voice.push(a.notes[i]);
        }
        return {id:Math.random().toString(), notes: voice};
    }

    // We want to iterate & query the events between 2 voices
    function first_moment(a, b) { return !a.notes.length && !b.notes.length ? undefined : Math.min(a.notes.length ? a.notes[0].start : 0xFFFFFFF, b.notes.length ? b.notes[0].start : 0xFFFFFFF); }
    function at(a, t) { return !a ? undefined : a.notes.binary_search(function(x) { return t >= x.start && t < x.end ? 0 : t - x.start; }); }
    function prev_moment(a, b, t)
    {
        a = a.notes.binary_search(function(x) { return t - x.start || -1; }, -1);
        b = b.notes.binary_search(function(x) { return t - x.start || -1; }, -1);
        if(!a && !b) return undefined;
        return Math.min(t-15, Math.max(a ? a.start : -Infinity, b ? b.start : -Infinity));
    }

    function next_moment(a, b, t)
    {
        a = a.notes.binary_search(function(x) { return t - x.start || 1; }, 1);
        b = b.notes.binary_search(function(x) { return t - x.start || 1; }, 1);
        if(!a && !b) return undefined;
        return Math.max(t+15, Math.min(a ? a.start : Infinity, b ? b.start : Infinity));
    }

    function extract_bass(voices, upper)
    {
        var bass = [];
        var end = 0;
        for(var i = 0; i < voices.length; ++i)
            if(voices[i].notes.length)
                end = Math.max(end, voices[i].notes[voices[i].notes.length-1].end);

        var inc = 30;
        for(i = 0; i <= end; i += inc)
        {
            var current_notes = voices.map(function(x) { return at(x, i); }).filter(function(x) { return x; });
            if(current_notes.length === 0) continue;
            var lowest = current_notes[0];

            for(var j = 1; j < current_notes.length; ++j)
                if ((!upper && current_notes[j].chroma_pitch < lowest.chroma_pitch) || (upper && current_notes[j].chroma_pitch > lowest.chroma_pitch))
                    lowest = current_notes[j];

            if(bass.length && lowest.chroma_pitch === bass[bass.length-1].chroma_pitch)
            {
                bass[bass.length-1].duration += inc;
                bass[bass.length-1].end += inc;
            }
            else
            {
                var beat = current_notes.filter(function(x){return x.start === i;})[0];
                bass.push({
                    chroma_pitch: lowest.chroma_pitch,
                    pitch: lowest.pitch,
                    start: i,
                    duration: inc,
                    end: i+ inc,
                    prev: bass.length ? bass[bass.length-1] : null,
                    next: null,
                    onbeat: beat && beat.onbeat
                });
                if(bass.length > 1) bass[bass.length-2].next = bass[bass.length-1];
            }
        }
        
        return  {id:Math.random().toString(), notes: bass};
    }


    //***************************************************
    // Implementation of basic music theoretical concepts
    //***************************************************

    // We need to ask some questions about the interaction between notes
    // motion is -1 no more notes, 0 = static, 1 = stepwise, 2 = leap
    function interval(a, b) { return a && b ? Math.abs(a.pitch - b.pitch) % 7 : undefined; }
    function chroma_interval(a, b) { return a && b ? Math.abs(a.chroma_pitch - b.chroma_pitch) % 12 : undefined; }
    function stepwise_7th(a, b) { return b && interval(a, b) === 6 && !b.onbeat; }
    function stepwise(a, b) { return interval(a, b) === 1 || stepwise_7th(a, b); }
    function substepwise(a, b) { return interval(a, b) <= 1 || stepwise_7th(a, b); }
    function tritone(a, b) { return chroma_interval(a, b) === 6 && (interval(a,b) === 3 || interval(a,b) === 4); }
    function dissonant_4th(a, b, bass) { return chroma_interval(a, b) === 5 && at(bass, Math.max(a.start, b.start)) && at(bass, Math.max(a.start, b.start)).chroma_pitch === Math.min(a.chroma_pitch, b.chroma_pitch); }
    function dissonant(a, b, bass) { return [1,6].includes(interval(a, b)) || (tritone(a, b) && !a.is_dim_chord && !b.is_dim_chord) || dissonant_4th(a, b, bass); }
    function perfect(a, b) { return [0,4].includes(interval(a, b)) && [0,7].includes(chroma_interval(a,b)); }
    function consonant(a, b, bass) { return !!a && !!b && !perfect(a, b) && !dissonant(a, b, bass); }
    function motion(a, b) { return a && b ? (stepwise(a, b) ? 1 : (chroma_interval(a, b) === 0 ? 0 : 2)) : -1; }
    function interval_salience(a, b) { return [0, 3,2, 1,1, 1,4,0, 1,1, 2,3][chroma_interval(a, b)]; }
    function accented(a, b) { return !!a && !!b && a.start === b.start; }
    function same(a, b, t) { return  !!a && !!b && at(a, t).chroma_pitch == at(b, t).chroma_pitch; }
    function direction(a, b) { return a.chroma_pitch === b.chroma_pitch ? 0 : (a.chroma_pitch < b.chroma_pitch ? 1 : -1);}

    // On the context of a dissonance
    // We want to be agnostic w.r.t. the amount of consecutive dissonances
    // So we have a generic 'preparation' and 'resolving' note
    function has_prev_dissonance(a, b, t, bass) { return dissonant(at(a, prev_moment(a, b, t)), at(b, prev_moment(a, b, t)), bass); }
    function has_next_dissonance(a, b, t, bass) { return dissonant(at(a, next_moment(a, b, t)), at(b, next_moment(a, b, t)), bass); }
    function prepare(a, b, t, bass) { for(var i = 0; i < 5 && has_prev_dissonance(a, b, t, bass); ++i) { t = prev_moment(a, b, t); } return prev_moment(a, b, t); }
    function resolve(a, b, t, bass) { for(var i = 0; i < 5 && has_next_dissonance(a, b, t, bass); ++i) { t = next_moment(a, b, t); } return next_moment(a ,b, t); }

    function moment_duration(a, b, t,bass) { return resolve(a,b,t,bass) - t; }
    function resolves_down(a, b, t, bass) { return at(a, t).pitch - at(a, resolve(a, b, t,bass)).pitch == 1; }
    function resolves_half_step(a, b, t, bass) { return chroma_interval(at(a, t), at(a, resolve(a, b, t,bass))) === 1; }
    function prepare_consonant(a, b, t, bass) { return consonant(at(a, prepare(a, b, t, bass)), at(b, prepare(a, b, t, bass)), bass); }
    function resolve_consonant(a, b, t, bass) { return consonant(at(a, resolve(a, b, t, bass)), at(b, resolve(a, b, t, bass)), bass); }


    // Between voice a & b there adjacent perfects at time t & t2, give some basic info on that movement.
    function perfect_info(a, b, t, t2, bass, upper)
    {
        var a1 = at(a, t); var a2 = at(a, t2); var b1 = at(b, t); var b2 = at(b, t2);
        
        if(a1.chroma_pitch == a2.chroma_pitch || b1.chroma_pitch == b2.chroma_pitch)
            return 0;

        var similar_motion = direction(a1, a2) == direction(b1, b2);
        if(!similar_motion)
            return 0;

        var is_bass_line = (same(a, bass, t) && same(a, bass, t2)) || (same(b, bass, t) && same(b, bass, t2));
        var is_upper_line = (same(a, upper, t) && same(a, upper, t2)) || (same(b, upper, t) && same(b, upper, t2));
        
        var diff_a = (a1.chroma_pitch - a2.chroma_pitch);
        var diff_b = (b1.chroma_pitch - b2.chroma_pitch);
        var parallel_motion = diff_a == diff_b;
        var distance = t2 - t;
        var start_strong = (a1.start == t && a1.onbeat) || (b1.start == t && b1.onbeat);
        var end_strong = (a2.start == t2 && a2.onbeat) || (b2.start == t2 && b2.onbeat);
        var start_direct = a1.start == b1.start;
        var end_direct = a2.start == b2.start;
        var nearby = distance <= 1920/2;

        var any = function(x, f)
        {
            for(; x && x.start < t2; x = x.next) if(f(x)) return true;
            return 0;
        }

        // peak == both high or low extremity relative to movement, eg: do all intermediate notes fit between the parallel candidates.
        var a1_is_peak = !any(a1, function(x) { return (a2.chroma_pitch < a1.chroma_pitch && x.chroma_pitch > a1.chroma_pitch) || (a2.chroma_pitch > a1.chroma_pitch && x.chroma_pitch < a1.chroma_pitch); });
        var a2_is_peak = !any(a1, function(x) { return (a2.chroma_pitch < a1.chroma_pitch && x.chroma_pitch < a2.chroma_pitch) || (a2.chroma_pitch > a1.chroma_pitch && x.chroma_pitch > a2.chroma_pitch); });
        var b1_is_peak = !any(b1, function(x) { return (b2.chroma_pitch < b1.chroma_pitch && x.chroma_pitch > b1.chroma_pitch) || (b2.chroma_pitch > b1.chroma_pitch && x.chroma_pitch < b1.chroma_pitch); });
        var b2_is_peak = !any(b1, function(x) { return (b2.chroma_pitch < b1.chroma_pitch && x.chroma_pitch < b2.chroma_pitch) || (b2.chroma_pitch > b1.chroma_pitch && x.chroma_pitch > b2.chroma_pitch); });
        
        var connection_direct = a2_is_peak && b2_is_peak;
        var start_is_peak = a1_is_peak && b1_is_peak;

        var parallel_perfect_audibility = 
            (parallel_motion?1:0) * 4 +
            (connection_direct?1:0) * 4 +
            (start_direct?1:0) * 2 +
            (end_direct?1:0) * 2 +
            (start_strong?1:0) * 3 +
            (end_strong?1:0) * 3 +
            (nearby?1:0) * 1 +
            (is_bass_line?1:0) * 0.7 +
            (is_upper_line?1:0) * 0.5 +
            (start_is_peak?1:0) * 0.5;

        return parallel_perfect_audibility;
        //return (start_direct?1:0) + (end_direct?1:0) + (parallel_motion?1:0) + (is_bass_line?1:0) + (is_upper_line?1:0) + (start_strong?1:0) + (end_strong?1:0) + ((a1_is_peak && b1_is_peak)?1:0) + ((b2_is_peak && a2_is_peak)?1:0)*2;
    }

    function match_dissonances(score)
    {
        console.log("loading music...")

        var voices = read_all_voices(score);
        var all_labels = [];
        var END = 0;

        console.log("finding end...")

        for(var i = 0; i < voices.length; ++i)
        {
            if(voices[i].notes.length > 1)
                END = Math.max(END, voices[i].notes[voices[i].notes.length-1].end);

            all_labels.push([]);
        }
        
        console.log("extracting outer voices...")

        var bass = extract_bass(voices, false);
        var upper = extract_bass(voices, true);

        console.log("detecting empty staves...")
        var any_notes = false;
        for(i = 0; i < voices.length; ++i)
            any_notes = any_notes || voices[i].notes.length > 0;

        if(!any_notes) return;


        console.log("iterating perfects...")
        var all_parallel_perfects = [];

        // Iterate over all perfect intervals between all voice pairs
        for(i = 0 ; i < voices.length; ++i)
        for(var j = i+1; j < voices.length; ++j)
        {
            var found_perfects = [];
            for(var t = first_moment(voices[i], voices[j]); t !== undefined && t !== null && t < END; t = next_moment(voices[i], voices[j], t))
            if(t >= 0 && perfect(at(voices[i], t), at(voices[j], t)))
            {
                for(var p = found_perfects.length-1; p >= 0 && found_perfects[p] >= t-1920; p--)
                {
                    var terribleness = perfect_info(voices[i], voices[j], found_perfects[p], t, bass, upper);
                    if(terribleness >= 4)
                    {
                        all_parallel_perfects.push([terribleness, found_perfects[p], t, i, j]);
                        console.log("Found parallel!", t, found_perfects[p], terribleness);
                    }
                }
                
                found_perfects.push(t);
            }
        }

        all_parallel_perfects = all_parallel_perfects.sort(function(x,y) { return y[0] - x[0]});

        for(var i = 0; i < all_parallel_perfects.length && i < 10; i++)
        {
            var p = all_parallel_perfects[i];
            all_labels[p[3]].push([p[1], p[0].toString()]);
            all_labels[p[3]].push([p[2], ""]);
            all_labels[p[4]].push([p[1], ""]);
            all_labels[p[4]].push([p[2], ""]);
        }

        console.log("placing labels...")

        var dissonanceCount = {};
        for(var staff = 0; staff < all_labels.length; ++staff)
        {
            var cursor = score.newCursor();
            cursor.staffIdx = Math.floor(staff / 4);
            cursor.voice = staff % 4;
            cursor.rewind(0);

            var staff_labels = all_labels[staff].sort();
            staff_labels = all_labels[staff].sort(function(x,y){ return (x[0]-y[0]) * 2 + (x[1] < y[1] ? 1 : -1); });
            var last_label = "";
            var last_time = -1;

            for(i = 0; i < staff_labels.length; ++i)
            {
                if(i && staff_labels[i-1][0] === staff_labels[i][0] && staff_labels[i-1][1] === staff_labels[i][1])
                    continue

                while(cursor.tick < staff_labels[i][0] && cursor.tick + cursor.element.duration.ticks <= staff_labels[i][0] && !cursor.eos)
                    cursor.next();

                //if(!(last_label === staff_labels[i][1] && last_time === cursor.tick))
                if(1)
                {
                    if(!dissonanceCount[staff_labels[i][1]]) dissonanceCount[staff_labels[i][1]] = [];

                    if(staff_labels[i][1])
                    {
                        dissonanceCount[staff_labels[i][1]].push(cursor.tick / (1920*2));
                        var labelElement = newElement(Element.STAFF_TEXT);
                        labelElement.text = staff_labels[i][1];
                        labelElement.offsetY = 1;
                        cursor.add(labelElement);
                    }
                   
                    last_label = staff_labels[i][1];
                    last_time = cursor.tick;
                    var note = cursor.element.notes ? cursor.element.notes[0] : cursor.element;
                    note.color = "#ff0000";
                }
            }
        }

        for(var x in dissonanceCount)
            if(typeof dissonanceCount[x] != "function")
                console.log(x, dissonanceCount[x].length, dissonanceCount[x].splice(0, 20));
    }

    onRun: {
        polyfill();

        if (typeof curScore == "undefined" || curScore == null) {
            console.log("no score found");
            Qt.quit();
        }

        match_dissonances(curScore);
        Qt.quit();
    }
}
