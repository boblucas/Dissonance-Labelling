import QtQuick 2.0
import QtQuick.Dialogs 1.1
import MuseScore 3.0

MuseScore {
    menuPath: "Plugins.Proof Reading.Name dissonances"
    description: "Labels your dissonances and also weeds out parallel perfects."
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


    //***********************************************************
    // Graph related code to implement a simple vertex cover algo
    //***********************************************************


    // this implements a simple Set-like data structure that can be used to store the edges of a graph
    // O(1) insert/erase/contains, O(N) merge/subtract, count is slow.
    function directed_edge_id(a, b) { return a + " " + b; }
    function edge_id(a, b) { return (a < b ? a : b) + " "  + (a < b ? b : a); }
    function pairSet(directed)
    {
        directed = directed || false;
        return {
            edge: directed ? directed_edge_id : edge_id,
            arr: {},
            insert: function(a, b) { this.arr[this.edge(a,b)] = true; },
            erase: function(a, b) { this.arr[this.edge(a,b)] = undefined; },
            contains: function(a, b) { return this.arr[this.edge(a,b)]; },
            merge : function(a)
            {
                var added = pairSet();
                for(var p in a.arr) if(!this.arr[p])
                    this.arr[p] = added.arr[p] = true;
                return added;
            },
            subtract : function(a)
            {
                for(var p in a.arr) this.arr[p] = undefined;
            },
            connected : function(a)
            {
                var result = [];
                for(var p in this.arr)
                {
                    var x = p.split(" ")[0];
                    var y = p.split(" ")[1];
                    result.push(x == a ? y : x);
                }
                return result;
            }
        };
    }

    // Find the components of a graph, m is an adjacency matrix (id -> PairSet)
    function components(m)
    {
        var result = [];
        var closed = {};
        var i;
        var connected;
      
        for(var node in m)
        {
            if(closed[node]) continue;
            closed[node] = true;
            var component = [node];
            var open = [node];
            while(count(open) > 0)
            {
                var x = open.pop();
                connected = m[x].connected(x);
                for(i = 0; i < connected.length; ++i)
                    if(!closed[connected[i]])
                    {
                        closed[connected[i]] = true;
                        open.push(connected[i]);
                        component.push(connected[i]);
                    }
            }

            var m2 = {};
            for(i = 0; i < component.length; ++i)
            {
                m2[component[i]] = pairSet();
                connected = m[component[i]].connected(component[i]);
                for(var j = 0; j < connected.length; ++j)
                     m2[component[i]].insert(component[i], connected[j]);
            }
            result.push(m2);
        }

        return result;
    }

    // weights maps a directed edge to a cost
    function cover_cost(weights, m, cover)
    {
        var total = 0;
        for(var edge in weights)
        {
            var has_a = cover.includes(edge.split(" ")[0]);
            var has_b = cover.includes(edge.split(" ")[1]);
            if(!has_a && !has_b) continue; // not a cover should never happen
            if(!has_a) total += weights[edge][1];
            else if(!has_b) total += weights[edge][0];
            else total += Math.min(weights[edge][0], weights[edge][1]);
        }
        return total + cover.length*0.01;
    }

    // Look for edges that have one direction of very high cost (wrong..) and one of very low cost
    // Just pick the low cost vertex immediately for that edge
    function _best_cover_optimized(m, w)
    {
        var state = [];
        var closed_edges = pairSet();
        var factor = 10;
        while(factor == 10 || count(m) - count(state) >= 12)
        {
            //if(factor < 10)
            //    console.log("reducing graph heuristically")

            for(var edge in w)
            {
                var a = edge.split(" ")[0];
                var b = edge.split(" ")[1];
                var c = null;
                if(w[edge][0] > w[edge][1]*factor) c = b;
                if(w[edge][1] > w[edge][0]*factor) c = a;
                if(c && m[c] && !state.includes(c))
                {
                    closed_edges.merge(m[c]);
                    state.push(c);
                }
            }

            factor /= 2;
        }

        //console.log("component size", count(m) - count(state))
        return _best_cover(m, w, 0, closed_edges, edge_count(m), { cover : null }, state, { count : 4096*4});
    }

    function _best_cover(m, w, j, closed_edges, edge_count, min_cover, state, total_compute)
    {
        total_compute.count -= 1;
        if(total_compute.count <= 0)
        {
            console.log("ran out of vertex cover compute time");
            return min_cover.cover;
        }
        if(count(closed_edges.arr) >= edge_count)
        {
            if(!min_cover.cover || cover_cost(w, m, min_cover.cover) > cover_cost(w, m, state))
                min_cover.cover = state.concat();
        }

        for(var i in m)
        {
            if(i < j || state.includes(i)) continue;
            var added = closed_edges.merge(m[i]);
            state.push(i);
            _best_cover(m, w, i + 1, closed_edges, edge_count, min_cover, state, total_compute);
            state.pop(i);
            closed_edges.subtract(added);
        }
        return min_cover.cover;
    }

    function edge_count(m)
    {
        var all_edges = {};
        for(var i in m) for(var e in m[i].arr)
            all_edges[e] = true;
        return count(all_edges);
    }

    function best_cover(m, w)
    {
        var c = components(m);
        var result = [];
        for(var i = 0; i < c.length; ++i)
        {
            result = result.concat(_best_cover_optimized(c[i], w));
        }
        return result;
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

            var beat = current_measure_length  / cursor.measure.timesigActual.numerator;
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
        var full_voices = [];
        for(var i = 0; i < score.nstaves; ++i)
        {
            var cursor = score.newCursor();
            var end = 0xFFFFFFF;
            cursor.rewind(2);
            if(cursor.segment) end = cursor.tick;
                cursor.rewind(cursor.segment ? 1 : 0);

            cursor.staffIdx = i;
            cursor.voice = 0;
            if(merge_notes)
                full_voices.push(merge_repeated_notes(read_voice(cursor, end)));
            else
                full_voices.push(read_voice(cursor, end));
        }
        return full_voices;
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

    function extract_range(v, t, n, context)
    {
        var slice = [];
        for(var i = 0; i < v.notes.length; ++i)
        {
            if(v.notes[i].end >= t-context && v.notes[i].start <= t+n+context)
            {
                var copy = {};
                for (var p in v.notes[i]) if(v.notes[i].hasOwnProperty(p)) copy[p] = v.notes[i][p];
                copy.start = (copy.start - t)|0;
                copy.end = (copy.end - t)|0;
                if(slice.length) copy.prev = slice[slice.length-1];
                if(slice.length) slice[slice.length-1].next = copy;
                slice.push(copy);
            }
        }
        return {id:Math.random().toString(), notes: slice};
    }

    function extract_bass(voices)
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
                if (current_notes[j].chroma_pitch < lowest.chroma_pitch)
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

    // The meat of deciding what kind of dissonance we are dealing with
    function dissonance_info(a, b, t, bass)
    {
        var WRONG = 0xFFFF;

        // normalize double dissonant to first dissonant note, avoid more than 2 dissonances
        if(has_prev_dissonance(a,b,t,bass) && has_next_dissonance(a, b, t,bass)) return WRONG;
        while(has_prev_dissonance(a,b,t,bass)) t = prev_moment(a, b, t);
        
        // make sure there is actual context for judging
        //if(prepare(a,b,t,bass) === undefined || resolve(a,b,t,bass) === undefined || at(b, prepare(a,b,t,bass)) === undefined || at(b, resolve(a,b,t,bass)) === undefined || at(a, prepare(a,b,t,bass))=== undefined || at(a, resolve(a,b,t,bass))=== undefined || at(a, next_moment(a, b, t))=== undefined || at(a, prev_moment(a, b, t)) === undefined)
        //    return WRONG;

        // We consider diminished chords consonant

        // Generally the forms below will explain a tritone resolution fine
        // but I would like to name the typical tritone V I seperately
        // as I think it holds additional musical meaning
        // tritone && half step resolution, and resolution is consonant
        //if(tritone(at(a, t), at(b, t)) && chroma_interval(at(a,t), at(a, t).next) == 1 && chroma_interval(at(b, t), at(b, at(a, t).next.start)) == 1 && consonant(at(a, t).next,  at(b, at(a, t).next.start), bass))
        //   return "TT";

        var tp = prev_moment(a, b, t);
        var M = [motion(at(a, tp), at(a, t))];
        for(var i = 0; i < 4; ++i)
        {
            tp = next_moment(a, b, tp);
            M.push(motion(at(a, tp), at(a, next_moment(a, b, tp))));
            M.push(motion(at(a, prev_moment(a, b, tp)), at(a, next_moment(a, b, tp))));
            
            if(i > 1) M.push(motion(at(a, t), at(a, next_moment(a, b, tp))));
        }
        // approach>diss, diss>resolve, approach>resolve,  resolve>resolve+1, diss>resolve+1,  resolve+1>resolve+2, resolve>resolve+2, diss > resolve+2, repeat

        //console.log(M);

        // Pattern matching on the motion to get the right name (or recognizes unknown types of dissonances)
        var _ = null;
        var patterns = [
            // single dissonance
            [
                [[1, 1,2], "PT"],
                [[1, 1,0], "NT"],
                [[0, 1,1], "SUS"], //resolves_down(a,b,t,bass) ? 'SUS' : 'RET',
                [[1, 0,1], "ANT"],
                [[1, 2,1], "ESC"],
                [[2, 1,1], "NT+"],
                [[2, 1,2], "APP"],
                [[0, 2,2, 1,1], "SUS+"],
                [[0, 2,2, 1,2, 1,2,1], "SUS++"],
                [[0, 2,2, 1,2, 1,2,2, 1,2,1], "SUS++"],
                [[0, 2,2, 2,1], "SUS*"],
                [[1, 2,2, 1,1], "CAMBIATA"]
            ],
            //double dissonance
            [
                [[1, 1,_, 1], "2PT"],
                [[1, 2,1, 1,1], "2NB"],
                [[0, 1,1, 1,2], "TS"],
                [[0, 2,2, 1,1], "SUS2"],
                [[0, 0,0, 2,2, 1,_,1], "SUS2"],
                [[0, 0,0, 0,0, 2,2,2, 1,_,1], "SUS2"],
                [[0, 0,0, 1,1], "SUS"],
                [[0, 0,0, 0,0, 1,1,1], "SUS"]
            ]
        ];

        // Unfortunately JS doesn't do pattern matching, but something like this
        var result = patterns[has_next_dissonance(a,b,t,bass) ? 1 : 0].filter(function(x) { return x[0].filter(function(y, i){ return y !== null && y != M[i]; }).length === 0; })[0];
        var name = result ? ""+result[1] : WRONG;
        var is_accented = accented(at(a, t), at(b, t)) || at(a, t).onbeat;

        // some additional rules on the interaction of various properties
        if(name === WRONG) return WRONG;
        if(is_accented && name === "CAMBIATA") return WRONG;
        //if(at(a, resolve(a,b,t,bass)).pitch == at(b, resolve(a,b,t,bass)).pitch && name != "PT" && name != "NT") return WRONG;
        //if(name == 'APP' && resolves_down(a,b,t,bass) == (at(a, prepare(a,b,t,bass)).pitch > at(a, t).pitch)) return WRONG;
        if(name === 'ANT' && at(a,t).onbeat) return WRONG;
        if(name === "2NB" && at(a, resolve(a, b, t, bass)).chroma_pitch !== at(a, prepare(a, b, t, bass)).chroma_pitch) return WRONG;
       

        //if(name == "2NB" && !at(a, prepare(a,b,t,bass)).onbeat) return WRONG;

        return name;
    }

    function is_dim_chord(voices, t)
    {
        var notes = voices.filter(function(x){ return at(x, t) !== undefined; }).map(function(x) { return at(x, t).chroma_pitch % 12; }).unique();
        
        var intervals = [];
        for(var i = 0; i < notes.length; ++i)
            for(var j = i+1; j < notes.length; ++j)
                intervals.push(Math.abs(notes[i] - notes[j]) % 12);

        return intervals.filter(function(x) { return x === 3 || x === 9; }).length >= 2;
    }

    function cache_dim_chords(voices)
    {
        for(var i = 0 ; i < voices.length; ++i)
        {
            var n = voices[i].notes[0];
            while(n)
            {
                // should be a list of timespans
                n.is_dim_chord = is_dim_chord(voices, n.start);
                n = n.next;
            }
        }
    }

    // Now just iterate all pairs of voices and query the dissonance_info on all dissonances
    function match_dissonances(score)
    {
        console.time("loading music");

        var WRONG = 0xFFFF;

        // Load all music
        var full_voices = read_all_voices(score);
        var all_labels = [];
        var END = 0;
        for(var i = 0; i < full_voices.length; ++i)
        {
            if(full_voices[i].notes.length > 1)
            {
                END = Math.max(END, full_voices[i].notes[full_voices[i].notes.length-1].end);
            }
            all_labels.push([]);
        }
        
        cache_dim_chords(full_voices);

        console.timeEnd("loading music");
        //console.time("extracting bassline");
        var full_bass = extract_bass(full_voices);
        //console.timeEnd("extracting bassline");

        // We only process a couple bars at a time because the VM get's mega slow when it has to deal
        // with large arrays (even though there are no linear operations)
        // and with large numbers (even though they fit in 64 bit integers)
        var graph = {};
        var weights = {};
        var names = {};
        var costs ={
            "TT": 1.1,
            "PT": 1,
            "NT": 1.0,
            "ANT": 1.9,
            "NT+": 1.5,
            "ESC": 1.5,
            "SUS": 2,
            "SUSd": 2.2,
            "SUS+": 2.2,
            "SUS*": 2.25,
            "SUS++": 2.3,
            "SUS2": 2.4,
            "TS": 1.6,
            "APP": 2,
            "CAMBIATA": 2.5,
            "2PT": 1.1,
            "2NB": 1.5,
            "DOUBLE_NEIGHBOUR": 2.5,
            "CR": 5,
            "?": 100
        };

        var BATCH = 1920*8;
        var OVERLAP = 1920*1;
        for(var tf = 0; tf < END; tf += BATCH)
        {
            console.time("analysing");
            var voices = [];
            var any_notes = false;
            for(i = 0; i < full_voices.length; ++i)
            {
                voices.push(extract_range(full_voices[i], tf, BATCH, OVERLAP));
                any_notes = any_notes || voices[i].notes.length > 0;
            }

            if(!any_notes) continue;

            var bass = extract_bass(voices);

            for(i = 0 ; i < voices.length; ++i)
            for(var j = i+1; j < voices.length; ++j)
            {
                var t = first_moment(voices[i], voices[j]);
                while(t !== undefined && t !== null)
                {
                    if(t >= 0 && t < BATCH && dissonant(at(voices[i], t), at(voices[j], t), bass))
                    {
                        var name_a = dissonance_info(voices[i], voices[j], t, bass);
                        var name_b = dissonance_info(voices[j], voices[i], t, bass);
                        //console.log(t, i, j, name_a, name_b);
                        if(name_a === WRONG) name_a = "?";
                        if(name_b === WRONG) name_b = "?";

                        var id_a = (at(voices[i], t).start+tf) + "_" + i;
                        var id_b = (at(voices[j], t).start+tf) + "_" + j;

                        if(!graph[id_a]) graph[id_a] = pairSet();
                        if(!graph[id_b]) graph[id_b] = pairSet();

                        graph[id_a].insert(id_a, id_b);
                        graph[id_b].insert(id_b, id_a);

                        names[edge_id(id_a, id_b)] = [id_a < id_b ? name_a : name_b, id_a < id_b ? name_b : name_a];
                        weights[edge_id(id_a, id_b)] = [id_a < id_b ? costs[name_a] : costs[name_b], id_a < id_b ? costs[name_b] : costs[name_a]];
                    }
                    t = next_moment(voices[i], voices[j], t);
                }
            }
            console.timeEnd("analysing");
        }

        // Given a set of voices that are dissonant simultaniously we build a graph of interdissonance and consider all node colorings so that each edge is connected to a colored node.
        // We then find the lowest cost coloring
        //console.log(print_json(graph));
        //console.log(print_json(weights));
        
        console.time("finding best vertex cover");
        var cover = best_cover(graph, weights);
        
        // Reduce vertex cover to actual minimal label placement
        for(var edge in names)
        {
            var a = edge.split(" ")[0];
            var b = edge.split(" ")[1];
            var has_a = cover.includes(a);
            var has_b = cover.includes(b);

            var mark = null;
            var label = null;
            if(has_a && !has_b)
            {
                mark = a;
                label = names[edge][0];
            }
            if(has_b && !has_a)
            {
                mark = b;
                label = names[edge][1];
            }
            if(has_a && has_b)
            {
                mark = weights[edge][0] < weights[edge][1] ? a : b;
                label = weights[edge][0] < weights[edge][1] ? names[edge][0] : names[edge][1];
            }
            
            all_labels[mark.split('_')[1]].push([mark.split('_')[0], label]);
        }
        console.timeEnd("finding best vertex cover");

        console.time("placing labels");
        var dissonanceCount = {};
        for(var staff = 0; staff < all_labels.length; ++staff)
        {
            var cursor = score.newCursor();
            cursor.staffIdx = staff;
            cursor.voice = 0;
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
                    dissonanceCount[staff_labels[i][1]].push(cursor.tick / (1920*2));

                    var labelElement = newElement(Element.STAFF_TEXT);
                    labelElement.text = staff_labels[i][1];
                    labelElement.offsetY = 1;
                    cursor.add(labelElement);

                    last_label = staff_labels[i][1];
                    last_time = cursor.tick;

                    var note = cursor.element.notes ? cursor.element.notes[0] : cursor.element;
                    note.color = "#ff0000";
                }
            }
        }

        console.timeEnd("placing labels");
        console.log("dissonance statistics:");
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
