Engine_grains : CroneEngine {

    classvar <nv = 6;
    classvar <nlMax = 14;
    classvar <wfCols = 128;
    classvar <minFrames = 4096;
    classvar <relLeave = 1.2;
    classvar <reportChunk = 4;
    classvar <recDir = "/home/we/dust/audio/grains/";
    classvar <recMinDur = 0.1;

    var <buffers, <silent, <voices, pg, pgv, dg;
    var dying, dyingUntil;
    var stateBus, reporter, reportRate, oState, nornsAddr;
    var curStride, reportSlots, trashIndex, curReportK = -1;
    var busMain, fxMain, fxDelay, fxShimmer, fxTilt, fxDimension;
    var fxEq, fxTape, fxShaper, fxWobble, fxBitcrush, fxWavefold;
    var fxResonator, fxGlitch, fxHaas, fxRotate, fxRingmod, fxStChorus, fxVibe, fxSpiral, fxGenloss, fxSub, fxReel, fxOtt, spiralBuffer;
    var voiceBus, vfilt, vfg, vfTok, filtKeys, filtSet, stateMsg, vfDef, vfOn, loopDef = \grainsloop;
    var wobbleBuffer, glitchBuffer, bufSine;
    var eqLow = 0, eqMid = 0, eqHigh = 0, glRatio = 0, glMix = 1;
    var vparams, gparams, nls, actives, wins, loadTok, loadReq, loadBusy;
    var recBuf, recSyn, recPath, recNorm = 0, recBegan, recOn = false, oRec, inL = 0, inR = 1;
    var fxTok, mainDef = \grainsmain, mainWidth = 1;

    *new { arg context, doneCallback; ^super.new(context, doneCallback); }

    updateEq { fxEq.run((eqLow != 0) || (eqMid != 0) || (eqHigh != 0)) }
    updateGlitch { this.fxRun(fxGlitch, (glRatio > 0) && (glMix > 0), 0.6) }

    fxRun { arg syn, on, tail = 0; var t = (fxTok[syn] ? 0) + 1; fxTok[syn] = t; if(on, { syn.set(\flush, 0); syn.run(true) }, { if(tail > 0, { syn.set(\flush, 1); fork { tail.wait; if(fxTok[syn] == t, { syn.run(false) }) } }, { syn.run(false) }) }); }

    setLimiter { arg on; var d = if(on, { \grainsmainlim }, { \grainsmain }); if(d == mainDef, { ^this }); mainDef = d; fxMain = Synth.replace(fxMain, d, [\bus, busMain.index, \out, context.out_b.index, \width, mainWidth]); }

    bounce { arg dur, name, xf = 0.05;
        fork {
            var dir = recDir;
            var frames = (context.server.sampleRate * dur).round.asInteger;
            var buf = Buffer.alloc(context.server, frames, 2);
            var syn;
            File.mkdir(dir);
            context.server.sync;
            syn = Synth.new(\grainsbounce, [\buf, buf, \bus, busMain.index, \xf, xf], context.xg, 'addToTail');
            (dur + xf + 0.3).wait;
            buf.write(dir ++ name ++ ".wav", "WAV", "float");
            context.server.sync;
            syn.free;
            buf.free;
            nornsAddr.sendMsg("/grains/bounce", 1);
        };
    }

    recStart { arg name, maxDur, gain = 1, norm = 0, src = 1, mon = 0;
        if(recOn, { ^this });
        recOn = true;
        recPath = recDir ++ name ++ ".wav";
        recNorm = norm;
        recBegan = nil;
        fork {
            var b, frames = (context.server.sampleRate * maxDur.clip(1, 300)).round.asInteger;
            File.mkdir(recDir);
            b = Buffer.alloc(context.server, frames, 2);
            context.server.sync;
            if(recOn, {
                recBuf = b;
                recBegan = Main.elapsedTime;
                recSyn = Synth.new(\grainsrec,
                    [\buf, b, \inL, inL, \inR, inR, \gain, gain, \src, src,
                     \mon, mon, \out, context.out_b.index, \run, 1],
                    context.xg, 'addToHead');
            }, {
                b.free;
            });
        };
    }

    recStop { arg save = 1;
        var syn = recSyn, buf = recBuf, path = recPath, norm = recNorm;
        var dur = if(recBegan.notNil, { Main.elapsedTime - recBegan }, { 0 });
        if(recOn.not, { ^this });
        recOn = false;
        recSyn = nil; recBuf = nil; recBegan = nil;
        if(syn.isNil or: { buf.isNil }, {
            nornsAddr.sendMsg("/grains/rec_done", 0);
            ^this
        });
        fork {
            var frames = (dur * context.server.sampleRate).round.asInteger.clip(0, buf.numFrames);
            syn.set(\run, 0, \gate, 0);
            0.06.wait;
            syn.free;
            if((save > 0) and: { dur > recMinDur }, {
                if(norm > 0, { buf.normalize(norm) });
                context.server.sync;
                buf.write(path, "WAV", "float", frames, 0);
                context.server.sync;
                0.15.wait;
                nornsAddr.sendMsg("/grains/rec_done", 1);
            }, {
                nornsAddr.sendMsg("/grains/rec_done", 0);
            });
            buf.free;
        };
    }

    retire { arg s, rel = 0.3;
        if(s.notNil, { s.moveToHead(dg); s.set(\rel, rel, \gate, 0) })
    }

    retireSlot { arg i, ly, rel;
        var s = voices[i][ly];
        if(s.notNil, {
            s.moveToHead(dg);
            s.set(\rel, rel, \gate, 0);
            dying[i][ly] = s;
            dyingUntil[i][ly] = Main.elapsedTime + (rel * 0.6);
            voices[i][ly] = nil;
        });
    }

    reviveSlot { arg i, ly;
        var s = dying[i][ly];
        if(s.isNil, { ^nil });
        dying[i][ly] = nil;
        if(Main.elapsedTime > dyingUntil[i][ly], { ^nil });
        s.moveToHead(pgv[i]);
        ^s
    }

    stopVoice { arg i;
        var t = Main.elapsedTime + (relLeave * 0.6);
        var any = false;
        nlMax.do({ arg ly;
            var s = voices[i][ly];
            if(s.notNil, {
                dying[i][ly] = s;
                dyingUntil[i][ly] = t;
                voices[i][ly] = nil;
                any = true;
            });
        });
        if(any, {
            pgv[i].set(\rel, relLeave, \gate, 0);
            nlMax.do({ arg ly;
                var s = dying[i][ly];
                if(s.notNil, { s.moveToHead(dg) });
            });
        });
        this.parkFilter(i);
    }

    runFilter { arg i;
        if(vfilt.isNil, { ^this });
        vfTok[i] = vfTok[i] + 1;
        vfOn[i] = true;
        if(vfilt[i].notNil, { vfilt[i].run(true) });
    }

    parkFilter { arg i;
        var tok;
        if(vfilt.isNil, { ^this });
        vfTok[i] = vfTok[i] + 1;
        tok = vfTok[i];
        fork {
            ((relLeave * 2) + 1).wait;
            if((tok == vfTok[i]) and: { actives[i].not }, {
                vfOn[i] = false;
                if(vfilt[i].notNil, { vfilt[i].run(false) });
            });
        };
    }

    filtValue { arg i, key;
        var v = vparams[i].at(key);
        if(v.isNil, { v = gparams.at(key) });
        ^v
    }

    filtArgs { arg i;
        var m = [\in, voiceBus[i].index, \out, busMain.index];
        filtKeys.do({ arg k;
            var v = this.filtValue(i, k);
            if(v.notNil, { m = m.add(k); m = m.add(v) });
        });
        ^m
    }

    filtWant { arg i;
        var c = this.filtValue(i, \cutoff) ? 20000, h = this.filtValue(i, \hpf) ? 20;
        ^if((c >= 19990) and: { h <= 20.5 }, { \grainsvoicedry }, { \grainsvoice })
    }

    checkFilter { arg i;
        var d, old;
        if(vfilt.isNil or: { vfilt[i].isNil }, { ^this });
        d = this.filtWant(i);
        if(d == vfDef[i], { ^this });
        vfDef[i] = d;
        old = vfilt[i];
        if(vfOn[i], {
            vfilt[i] = Synth.after(old, d, this.filtArgs(i));
            old.set(\gate, 0);
        }, {
            vfilt[i] = Synth.newPaused(d, this.filtArgs(i), old, \addAfter);
            old.free;
        });
    }

    filtKey { arg key; ^(key == \cutoff) or: { key == \hpf } }

    pushFilter { arg i;
        var m;
        if(vfilt.isNil or: { vfilt[i].isNil }, { ^this });
        m = this.filtArgs(i).drop(4);
        if(m.size > 0, { vfilt[i].set(*m) });
        this.checkFilter(i);
    }

    setWin { arg msg, pairs;
        var i = msg[1].asInteger, n, base, m;
        if((i < 0) or: { i >= nv }, { ^this });
        n = min(pairs, curStride);
        base = i * nlMax * 2;
        m = Array.new(n);
        n.do({ arg ly;
            var s = voices[i][ly];
            var a = msg[(ly * 2) + 2], b = msg[(ly * 2) + 3];
            if(a.notNil and: { b.notNil }, {
                wins[base + (ly * 2)] = a;
                wins[base + (ly * 2) + 1] = b;
                if(s.notNil, { m = m.add(s.setMsg(\posStart, a, \posEnd, b)) });
            });
        });
        if(m.size > 0, { context.server.sendBundle(nil, *m) });
    }

    stateIndex { arg i, ly;
        if(ly >= curStride, { ^trashIndex });
        ^stateBus.index + (i * curStride) + ly
    }

    setReport { arg chans;
        var k = (chans / reportChunk).ceil.asInteger.clip(0, reportSlots);

        if(k == curReportK and: { (k == 0) or: { reporter.notNil } }, { ^this });
        curReportK = k;
        if(reporter.notNil, { reporter.free; reporter = nil });
        if(k > 0, {
            reporter = Synth.new(("grainsreport" ++ k).asSymbol,
                [\bus, stateBus.index, \rate, reportRate], context.xg, 'addToTail');
        });
    }

    setGeom { arg n, stride;
        var s = stride.clip(1, nlMax);
        if(s != curStride, {
            curStride = s;
            nv.do({ arg i;
                nlMax.do({ arg ly;
                    var at = this.stateIndex(i, ly);
                    var syn = voices[i][ly];
                    if(syn.notNil, { syn.set(\statebus, at) });
                    syn = dying[i][ly];
                    if(syn.notNil, { syn.set(\statebus, at) });
                });
            });
        });
        this.setReport(n.clip(0, nv) * curStride);
    }

    clearState { arg i;
        curStride.do({ arg ly; stateBus.setAt((i * curStride) + ly, 0) });
    }

    seeds {
        ^[\kTune, rrand(1.5, 5.0), \kDir, rrand(3.0, 9.0), \kAmp, rrand(2.5, 7.0),
          \kPan, rrand(4.0, 12.0), \phAmp, 2pi.rand, \phPan, 2pi.rand,
          \lagAmp, rrand(0.1, 0.7)]
    }

    reseedAll {
        var m = Array.new(nv * nlMax);
        nv.do({ arg i;
            nlMax.do({ arg ly;
                var s = voices[i][ly];
                if(s.notNil, { m = m.add(s.setMsg(*this.seeds)) });
            });
        });
        if(m.size > 0, { context.server.sendBundle(nil, *m) });
    }

    reseedVoice { arg i;
        var m;
        if((i < 0) or: { i >= nv }, { ^this });
        m = Array.new(nlMax);
        nlMax.do({ arg ly;
            var s = voices[i][ly];
            if(s.notNil, { m = m.add(s.setMsg(*this.seeds)) });
        });
        if(m.size > 0, { context.server.sendBundle(nil, *m) });
    }

    layerArgs { arg i, ly;
        var w = ((i * nlMax) + ly) * 2;
        var a = Array.new(96);
        var put = { arg k, v; a = a.add(k); a = a.add(v) };
        put.(\bus, voiceBus[i].index);
        put.(\buf, buffers[i]);
        gparams.keysValuesDo({ arg k, v;
            if(filtSet.includes(k).not, { put.(k, v) });
        });
        vparams[i].keysValuesDo({ arg k, v;
            if(filtSet.includes(k).not, { put.(k, v) });
        });
        this.seeds.pairsDo({ arg k, v; put.(k, v) });
        put.(\posStart, wins[w]);
        put.(\posEnd, wins[w + 1]);
        put.(\statebus, this.stateIndex(i, ly));
        ^a
    }

    startLayer { arg i, ly;
        var s = this.reviveSlot(i, ly);
        if(s.notNil, {
            this.retire(voices[i][ly]);
            voices[i][ly] = s;
            s.set(*(this.layerArgs(i, ly) ++ [\gate, 1]));
            ^this
        });
        this.retire(voices[i][ly]);
        voices[i][ly] = Synth.head(pgv[i], loopDef, this.layerArgs(i, ly));
    }

    setQuality { arg q;
        var d = if(q > 0, { \grainsloopeco }, { \grainsloop });
        if(d == loopDef, { ^this });
        loopDef = d;
        nv.do({ arg i;
            nlMax.do({ arg ly; dying[i][ly] = nil });
            if(actives[i] and: { buffers[i] !== silent }, {
                nls[i].min(nlMax).do({ arg ly;
                    this.retire(voices[i][ly], 0.4);
                    voices[i][ly] = Synth.head(pgv[i], loopDef, this.layerArgs(i, ly) ++ [\i_intro, 0.15]);
                });
            });
        });
    }

    startVoice { arg i;
        if(actives[i].not, { ^this.stopVoice(i) });
        this.runFilter(i);
        this.pushFilter(i);
        nlMax.do({ arg ly;
            if(ly < nls[i], {
                this.startLayer(i, ly);
            }, {
                this.retireSlot(i, ly, relLeave);
            });
        });
    }

    setLayers { arg i, n;
        var want = n.clip(1, nlMax);
        if(nls[i] == want, { ^this });
        nls[i] = want;
        if(actives[i].not or: { buffers[i] === silent }, { ^this });
        nlMax.do({ arg ly;
            if(ly < want, {
                if(voices[i][ly].isNil, { this.startLayer(i, ly) });
            }, {
                this.retireSlot(i, ly, relLeave);
            });
        });
    }

    setVoice { arg i, key, val;
        vparams[i].put(key, val);
        if(filtSet.includes(key), {
            if(vfilt[i].notNil, { vfilt[i].set(key, val) });
            if(this.filtKey(key), { this.checkFilter(i) });
            ^this
        });
        pgv[i].set(key, val);
    }

    clearParam { arg i, key;
        var g;
        vparams[i].removeAt(key);
        g = gparams.at(key);
        if(filtSet.includes(key), {
            if(g.notNil and: { vfilt[i].notNil }, { vfilt[i].set(key, g) });
            if(this.filtKey(key), { this.checkFilter(i) });
            ^this
        });
        if(g.notNil, { pgv[i].set(key, g) });
    }

    setAllVoices { arg key, val;
        gparams.put(key, val);
        if(filtSet.includes(key), {
            nv.do({ arg i;
                if(vparams[i].at(key).isNil and: { vfilt[i].notNil }, {
                    vfilt[i].set(key, val);
                    if(this.filtKey(key), { this.checkFilter(i) });
                });
            });
            ^this
        });
        pg.set(key, val);
    }

    readFailed { arg i, token;
        if(token.notNil and: { token != loadTok[i] }, { ^this });
        loadTok[i] = loadTok[i] + 1;
        nornsAddr.sendMsg("/grains/fail", i);
    }

    readChunk { arg i, path, chunkDur = 12, randomStart = 1, startSec = 0;
        path = path.asString;
        if(File.exists(path).not, { ^this.readFailed(i) });
        loadTok[i] = loadTok[i] + 1;
        loadReq[i] = [path, chunkDur, randomStart, startSec, loadTok[i]];
        if(loadBusy[i].not, { this.loadLoop(i) });
    }

    loadLoop { arg i;
        loadBusy[i] = true;
        fork {
            while({ loadReq[i].notNil }, {
                var r = loadReq[i];
                loadReq[i] = nil;
                { this.loadChunk(i, *r) }.try({ arg e; e.reportError; this.readFailed(i, r[4]) });
            });
            loadBusy[i] = false;
        };
    }

    loadChunk { arg i, path, chunkDur, randomStart, startSec, token;
        var s = context.server, sf, frames, sr, ch, num, start, b, peaks, blk, old;
        if(token != loadTok[i], { ^this });
        sf = SoundFile.openRead(path);
        if(sf.isNil, { ^this.readFailed(i, token) });
        frames = sf.numFrames; sr = sf.sampleRate; ch = sf.numChannels.max(1);
        if((frames <= minFrames) or: { sr <= 0 }, { sf.close; ^this.readFailed(i, token) });
        num = min(frames, (chunkDur * sr).asInteger).max(minFrames).min(frames).min(16777216);
        start = if((randomStart > 0) and: { frames > num }, { (frames - num).rand }, { (startSec * sr).asInteger.clip(0, max(frames - num, 0)) });
        b = Buffer.readChannel(s, path, start, num, [0]);
        blk = Signal.newClear(min(4096, max(1, num div: wfCols)) * ch);
        peaks = Array.fill(wfCols, { arg c; sf.seek(start + (c / wfCols * num).asInteger, 0); sf.readData(blk); if(c % 16 == 15, { 0.wait }); blk.peak });
        sf.close;
        s.sync;
        if(token != loadTok[i], { ^b.free });
        if(b.numFrames.isNil, { b.free; ^this.readFailed(i, token) });
        old = buffers[i];
        buffers[i] = b;
        this.startVoice(i);
        if(old.notNil and: { old !== silent }, { fork { 2.5.wait; old.free } });
        nornsAddr.sendMsg(*(["/grains/waveform", i] ++ peaks ++ [start / sr]));
    }

    moveVoice { arg src, dst;
        var b, ln, old;
        if((src < 0) or: { src >= nv } or: { dst < 0 } or: { dst >= nv } or: { src == dst }, { ^this });

        loadTok[src] = loadTok[src] + 1;
        loadTok[dst] = loadTok[dst] + 1;

        b = buffers[src];
        ln = nls[src];
        old = buffers[dst];

        buffers[dst] = b;
        nls[dst] = ln;
        vparams[dst] = vparams[src].copy;

        actives[dst] = actives[src];

        buffers[src] = silent;
        nls[src] = 1;
        vparams[src] = Dictionary.new;
        actives[src] = false;

        this.stopVoice(src);
        this.clearState(src);

        if(old.notNil and: { old !== silent }, { fork { 2.5.wait; old.free }; });

        this.clearState(dst);
        this.pushFilter(src);
        if(b === silent, {
            this.stopVoice(dst);
        }, {
            this.startVoice(dst);
        });
    }

    alloc {
        var t9dub = { arg x, f, amt, k1, k2; var d = x - OnePole.ar(x, 1 - f), h = (Delay1.ar(d) * (k2 / k1) + d).clip2(1 / k1), m = h.abs; x + (h * OnePole.ar(m / log(m * (255 * k1) + 1).max(1e-9), 1 - f) * (amt * (2.40823997 * k1 * k1))) };
        var csoft = { arg v; var c = v.clip2(1); c * (c.squared * -0.5 + 1.5) }, tri = { arg d; 1 - ((d - 2048).abs * 0.00048828125) };
        nornsAddr = NetAddr("127.0.0.1", 10111);

        inL = -1;
        try {
            if(context.in_b.isKindOf(Bus), {
                inL = context.in_b.index;
                inR = inL + 1;
            }, {
                inL = context.in_b[0].index;
                inR = context.in_b[1].index;
            });
        } { inL = -1 };
        if(inL < 0, {
            inL = context.server.options.numOutputBusChannels;
            inR = inL + 1;
        });

        fxTok = IdentityDictionary.new;
        filtKeys = [\cutoff, \res, \hpf, \vamp, \vampLag];
        filtSet = IdentitySet.newFrom(filtKeys);
        silent = Buffer.alloc(context.server, context.server.sampleRate.asInteger, 1);
        buffers = Array.fill(nv, { silent });
        vfTok = Array.fill(nv, { 0 });
        voices = Array.fill(nv, { Array.fill(nlMax, { nil }) });
        dying = Array.fill(nv, { Array.fill(nlMax, { nil }) });
        dyingUntil = Array.fill(nv, { Array.fill(nlMax, { 0 }) });
        vparams = Array.fill(nv, { Dictionary.new });
        gparams = Dictionary.new;
        nls = Array.fill(nv, { 1 });
        actives = Array.fill(nv, { false });
        wins = Array.fill(nv * nlMax * 2, { arg k; (k % 2) });
        loadTok = Array.fill(nv, { 0 });
        loadReq = Array.fill(nv, { nil });
        loadBusy = Array.fill(nv, { false });

        stateBus = Bus.control(context.server, (nv * nlMax) + 1);
        trashIndex = stateBus.index + (nv * nlMax);
        curStride = nlMax;
        reportSlots = ((nv * nlMax) / reportChunk).ceil.asInteger;
        busMain = Bus.audio(context.server, 2);
        voiceBus = Array.fill(nv, { Bus.audio(context.server, 2) });

        bufSine = Buffer.alloc(context.server, 4096, 1);
        bufSine.sine2([2], [0.5], false);
        wobbleBuffer = Buffer.alloc(context.server, context.server.sampleRate.asInteger, 2);
        glitchBuffer = Buffer.alloc(context.server, context.server.sampleRate.asInteger * 10, 2);
        spiralBuffer = Buffer.alloc(context.server, context.server.sampleRate * 3, 2);

        context.server.sync;

        [\grainsloop, \grainsloopeco].do({ arg defName, eco;
        SynthDef(defName, {
            arg bus, buf, statebus = 0, posStart = 0, posEnd = 1, mrate = 1, prate = 1, gate = 1, rel = 1, rateSlew = 1.5, vrate = 1, weight1 = 14, weight2 = 8, weight3 = 3, weight4 = 6, weight5 = 4, lrate1 = 1, lrate2 = 0.5, lrate3 = 4, lrate4 = 2, lrate5 = 0.25, lamp1 = 1, lamp2 = 1.5849, lamp3 = 0.1259, lamp4 = 0.3981, lamp5 = 1.2589, revprob = 0.1, panwidth = 0.5, ampfloor = 0.25, kTune = 3, kDir = 6, kAmp = 4.5, kPan = 8, phAmp = 0, phPan = 0, lagAmp = 0.4, i_intro = 1;

            var frames, edge, edge2, use, span, pmax, emax, rscale;
            var boot, idx, rate, amp2, lfoAmp, lfoPan, pStart, pEnd, sl, switch, nsw, resetTo;
            var pos1, pos2, snd1, snd2, posK, xfr, settled, snd, volume;

            frames = BufFrames.kr(buf).max(4096);
            span   = (frames * 0.04).min(2048);
            edge   = (SampleRate.ir * 0.2).min(frames * 0.02).max((frames * 0.005).min(256));
            edge2  = edge * 2;
            use    = frames - edge2;
            pmax   = frames - span - edge;
            emax   = frames - edge;
            rscale = BufRateScale.kr(buf);

            boot = Impulse.kr(0);
            idx  = TWindex.kr(boot + Dust.kr(prate / kTune), [weight1, weight2, weight3, weight4, weight5], 1);
            rate = vrate * Select.kr(idx, [lrate1, lrate2, lrate3, lrate4, lrate5]);
            amp2 = Select.kr(idx, [lamp1, lamp2, lamp3, lamp4, lamp5]);
            rate = Lag.kr(rate * (TRand.kr(0, 1, Impulse.kr(mrate / kDir)) >= revprob).madd(2, -1), rateSlew) * rscale;

            lfoAmp = SinOsc.kr(mrate / kAmp, phAmp, 1 - ampfloor, 1 + ampfloor);
            lfoPan = SinOsc.kr(mrate / kPan, phPan, panwidth);

            pStart = Clip.kr(posStart.madd(use, edge), edge, pmax);
            pEnd   = Clip.kr(posEnd.madd(use, edge), pStart + span, emax);
            sl     = (rate.abs.max(0.05) * (SampleRate.ir * 4) / (pEnd - pStart).min(edge2)).clip(33.333333, 333.33333);

            switch  = ToggleFF.kr(LocalIn.kr(1));
            nsw     = 1 - switch;
            resetTo = Select.kr(rate > 0, [pEnd, pStart]);

            if(eco > 0, {
                pos1 = Phasor.ar(nsw, rate, 0, frames, resetTo);
                snd1 = BufRd.ar(1, buf, pos1, 1.0, 2);
                pos2 = Phasor.ar(switch, rate, 0, frames, resetTo);
                snd2 = BufRd.ar(1, buf, pos2, 1.0, 2);
                posK = Select.kr(switch, [A2K.kr(pos1), A2K.kr(pos2)]);
            }, {
                pos1 = rate * (SampleRate.ir * ControlDur.ir);
                pos2 = Phasor.kr(switch, pos1, 0, frames, resetTo);
                pos1 = Phasor.kr(nsw, pos1, 0, frames, resetTo);
                snd1 = PlayBuf.ar(1, buf, rate, nsw, resetTo, 1);
                snd2 = PlayBuf.ar(1, buf, rate, switch, resetTo, 1);
                posK = Select.kr(switch, [pos1, pos2]);
            });

            xfr     = Slew.kr(switch, sl, sl);
            settled = (xfr - switch).abs < 1e-4;
            LocalOut.kr((Impulse.kr(25) - boot) * (settled > InRange.kr(posK, pStart, pEnd)));

            snd = LinXFade2.ar(snd1, snd2, xfr.squared.madd(xfr.madd(-4, 6), -1));

            volume = lfoAmp * EnvGen.kr(Env.new([0, 0.25, 1], [Rand(0.5, 2) * i_intro, Rand(1, 3) * i_intro], [4, -3]))
                * EnvGen.kr(Env.adsr(1, 1, 1, rel), gate + boot, doneAction: 2) * Lag.kr(amp2, lagAmp);

            Out.kr(statebus, ((posK - edge) / use).clip(0, 1));
            Out.ar(bus, Pan2.ar(snd, lfoPan, volume));
        }).add;
        });

        SynthDef(\grainsvoice, {
            arg in, out, cutoff = 20000, res = 0.3, hpf = 20, vamp = 0.25, vampLag = 1, gate = 1;
            var sig = HPF.ar(In.ar(in, 2), Lag.kr(hpf, 0.1));
            sig = RLPF.ar(sig, Lag.kr(cutoff, 0.1), res);
            Out.ar(out, sig * (Lag.kr(vamp, vampLag) * EnvGen.kr(Env.asr(0.05, 1, 0.05), gate, doneAction: 2)));
        }).add;

        SynthDef(\grainsvoicedry, {
            arg in, out, vamp = 0.25, vampLag = 1, gate = 1;
            Out.ar(out, In.ar(in, 2) * (Lag.kr(vamp, vampLag) * EnvGen.kr(Env.asr(0.05, 1, 0.05), gate, doneAction: 2)));
        }).add;

        reportSlots.do({ arg k;
            SynthDef(("grainsreport" ++ (k + 1)).asSymbol, { arg bus = 0, rate = 30;
                SendReply.kr(Impulse.kr(rate.clip(2, 60)), '/grains_state',
                    In.kr(bus, (k + 1) * reportChunk));
            }).add;
        });

        SynthDef(\grainseq, {
            arg bus, low = 0, mid = 0, high = 0;
            var sig = In.ar(bus, 2);
            sig = BLowShelf.ar(sig, 55, 6, Lag.kr(low, 0.05));
            sig = BPeakEQ.ar(sig, 700, 1, Lag.kr(mid, 0.05));
            sig = BHiShelf.ar(sig, 3900, 6, Lag.kr(high, 0.05));
            ReplaceOut.ar(bus, sig);
        }).add;

        SynthDef(\grainstape, {
            arg bus;
            var os = SampleRate.ir / 44100, sh = 0.596, fd = 0.6.pow(6) * 0.0011338, fhz = 0.4.cubed * 140.37, ob = 0.865.cubed * 44100, d, hs, x2, hb, lk;
            var sig = t9dub.(In.ar(bus, 2) * 2.25 + WhiteNoise.ar(1e-18), (1 - sh) / os, 1.2, 2.848, 1.152);
            sig = DelayC.ar(sig, 0.003, SinOsc.kr(fhz * LFNoise1.kr(fhz * 0.5 ! 2).range(0.24, 0.98), pi, fd, fd));
            sig = Slew.ar(sig, ob, ob);
            d = Delay1.ar(sig) - sig;
            hs = ((Delay1.ar(d * 0.5 + sig) - sig).abs * 0.12).min(1);
            hs = hs * (hs * -0.5 + 1);
            sig = (d * hs + sig).clip2(2.305929);
            x2 = sig.squared;
            sig = sig * (x2 * (x2 * (x2 * (x2 * (x2 * -0.000000100208 + 0.00000444473) - 0.0003952447) + 0.014492754) - 0.16666667) + 1);
            sig = (Delay1.ar(sig) - sig) * hs + sig;
            lk = (OnePole.ar(LocalIn.ar(2).squared, 0.998) * (0.0927 / os)).clip(1e-6, 0.9);
            hb = OnePole.ar(sig * (0.066 / os) * (1 - lk) / lk, 1 - lk);
            LocalOut.ar(hb);
            hb = BPF.ar(BPF.ar(hb, 60, 1.618), 56.25, 1.618);
            sig = (t9dub.(hb * 0.33 + sig, sh / os, -0.8, 2.628, 1.372) * 0.6309573).clip2(0.9085097);
            x2 = HPZ1.ar(sig).abs;
            ReplaceOut.ar(bus, sig.clip2(0.94 / (x2.max(Delay1.ar(x2)) * 2.7972026 + 1)));
        }).add;

        SynthDef(\grainsringmod, {
            arg bus, mix=0, rate=800, sweep=0.3;
            var x = In.ar(bus, 2), c = SinOsc.ar(rate * [1, 1.006] * SinOsc.kr(sweep.squared * [12, 9.96], 0, sweep * 0.75, 1));
            ReplaceOut.ar(bus, (x * c * 0.5 - x) * mix + x);
        }).add;

        SynthDef(\grainsstchorus, {
            arg bus, mix=0;
            var dry = In.ar(bus, 2), sp = (0.5 / 6 + 0.32).pow(10), dp = 0.6 / 60 / sp;
            var air = OnePole.ar(dry * 252.1646, -0.9921), t = SinOsc.ar(sp * 7018.73, [1.16355, pi], dp, dp + 1) / 44100;
            var wet = DelayN.ar(HPZ2.ar(air), 0.14, t) * -0.04 + DelayL.ar(LPZ1.ar(air), 0.14, t);
            ReplaceOut.ar(bus, XFade2.ar(dry, wet, mix * 2 - 1));
        }).add;

        SynthDef(\grainsvibe, {
            arg bus, drift = 0.5, mix = 0;
            var x = In.ar(bus, 2), p = Phasor.kr(0, LocalIn.kr(1).max(0.4294967) * drift.cubed * 0.001 * SampleRate.ir * ControlDur.ir, 0, 2pi), ph = (p + 3) % 2pi;
            var wet = DelayL.ar(x, 260 * SampleDur.ir, (129 - (127 * [sin(ph), cos(ph)])) * SampleDur.ir);
            LocalOut.kr(TRand.kr(0.4294967, 0.6949, HPZ1.kr(p) < 0));
            ReplaceOut.ar(bus, x + ((wet - x) * mix));
        }).add;

        SynthDef(\grainsspiral, {
            arg bus, mix=0, bpm=120, div=0.5, feedback=0.5, rise=0.75, glide=0, span=0.5, tone=0.5, flush=0;
            var x = In.ar(bus, 2), sr = SampleRate.ir, frames = BufFrames.ir(spiralBuffer), soft = csoft;
            var mono = x.sum * 0.5, ax = mono.abs, d = (sr * 60 / bpm * div).clip(sr * 0.0348, sr * 2.72);
            var envF = A2K.kr(OnePole.ar(ax, 0.98)), envS = A2K.kr(OnePole.ar(ax, 0.9992)), peak = PeakFollower.kr(envF, 0.99995465 ** (sr * ControlDur.ir));
            var fbT = LocalIn.kr(1), t = (envF > (envS * 1.7 + 0.008)) * (1 - SetResetFF.kr(fbT, envF < (peak * 0.08))) * (1 - Trig1.kr(fbT, 0.25));
            var ramp = 1 - Decay.kr(t, 6.9078 / (((1 - span).cubed * 1.13e-4 + 2.8e-6) * 44100)).min(1);
            var ratio = (Select.kr(rise < 0.5, [rise * 2, rise + 0.5]) * (glide * 0.6 * ramp * ((rise >= 0.5) * 2 - 1) + 1)).clip(0.25, (d / 1024).clip(1.05, 4));
            var gtrig = Impulse.ar(sr / 1024), gt = Sweep.ar(gtrig, sr), wp = Phasor.ar(0, 1, 0, frames), e, lp;
            LocalOut.kr(t);
            e = (gt.min(1024 - gt) * 0.001953125).clip(0, 1);
            lp = OnePole.ar(BufRd.ar(2, spiralBuffer, (Latch.ar(wp - d, gtrig) + Sweep.ar(gtrig, ratio * sr)).wrap(0, frames), 1, 2) * (e * e * (3 - (2 * e))), 0.97 - (tone * 0.5));
            BufWr.ar(soft.(lp * (feedback * 0.965) + x) * (1 - flush), spiralBuffer, wp);
            ReplaceOut.ar(bus, (soft.(x + lp) - x) * mix + x);
        }).add;

        SynthDef(\grainsgenloss, {
            arg bus, mix=0;
            var x = In.ar(bus, 2), m = SinOsc.ar(0.7, 0, 132) + SinOsc.ar(8, 0, 30) + OnePole.ar(WhiteNoise.ar(90), 0.9988);
            var w = DelayL.ar(csoft.(x * 1.8), 0.025, (m + 529) / 44100);
            w = OnePole.ar(w - OnePole.ar(w, 0.988), 0.77) + WhiteNoise.ar(0.0006 ! 2);
            ReplaceOut.ar(bus, (w * 1.15 - x) * mix + x);
        }).add;

        SynthDef(\grainssub, {
            arg bus, mix=0, detune=0.65;
            var x = In.ar(bus, 2), mono = x.sum * 0.5, off = SinOsc.kr(0.15, 0, detune * 0.0173287), s = SampleDur.ir;
            var d1 = (Phasor.ar(0, [0.5 - off, 0.5 + off], 0, 4096) + [0, 2048]) % 4096, d2 = (d1 + 2048) % 4096;
            var v = DelayL.ar(mono, 0.1, d1 * s) * tri.(d1) + (DelayL.ar(mono, 0.1, d2 * s) * tri.(d2));
            ReplaceOut.ar(bus, (OnePole.ar(csoft.(v * 2.5), 0.89 ** (44100 * s)) - x) * mix + x);
        }).add;

        SynthDef(\grainsreel, {
            arg bus, mix=0;
            var x = In.ar(bus, 2), w = OnePole.ar(csoft.(x * 4.24 + 0.1) - 0.1495, 0.58) * 0.612;
            ReplaceOut.ar(bus, (w - x) * mix + x);
        }).add;

        SynthDef(\grainsott, {
            arg bus, mix = 0;
            var x = In.ar(bus, 2), f1 = 88.3, f2 = 2500, amt = Lag.kr(mix, 0.1);
            var lo = LPF.ar(LPF.ar(x, f1), f1), rest = HPF.ar(HPF.ar(x, f1), f1);
            var mid = LPF.ar(LPF.ar(rest, f2), f2), hi = HPF.ar(HPF.ar(rest, f2), f2);
            var wet = [[BAllPass.ar(lo, f2, 1.4142), -33.8, -40.8, 0.0478, 0.282, 10.3, 0.15], [mid, -30.2, -41.8, 0.0224, 0.282, 5.7, 0.1], [hi, -35.5, -40.8, 0.0135, 0.132, 10.3, 0.02]].collect({ arg p;
                var b = p[0], lvl = (A2K.kr(Lag.ar((b[0].squared + b[1].squared) * 0.5, p[6])).max(1e-10).log10 * 10) + 3;
                var g = ((p[1] - lvl).min(0) * 0.985) + ((p[2] - lvl).clip(0, 36) * (((lvl + 90) * 0.05).clip(0, 1) * 0.76));
                b * ((LagUD.kr(g, p[4], p[3]) + p[5] + 6) * amt).dbamp
            }).sum;
            ReplaceOut.ar(bus, wet);
        }).add;

        SynthDef(\grainsshaper, {
            arg bus, mix = 0;
            var orig = In.ar(bus, 2);
            var shaped = Shaper.ar(bufSine, orig * 1.5);
            ReplaceOut.ar(bus, SelectX.ar(mix, [orig, shaped]));
        }).add;

        SynthDef(\grainswobble, {
            arg bus, mix = 0.0, wobble_amp = 0.05, wobble_rpm = 33, flutter_amp = 0.03, flutter_freq = 6, flutter_var = 2, flush = 0;
            var pr, pw, rate, wet, flutter, wow, dry;
            dry = In.ar(bus, 2);
            wow = wobble_amp * SinOsc.kr(wobble_rpm / 60, mul: 0.2);
            flutter = flutter_amp * SinOsc.kr(flutter_freq + LFNoise2.kr(flutter_var), mul: 0.1);
            rate = 1 + (wow + flutter);
            pw = Phasor.ar(0, BufRateScale.ir(wobbleBuffer), 0, BufFrames.ir(wobbleBuffer));
            BufWr.ar(dry * (1 - flush), wobbleBuffer, pw);
            pr = DelayL.ar(Phasor.ar(0, BufRateScale.ir(wobbleBuffer) * rate, 0, BufFrames.ir(wobbleBuffer)), 0.2, 0.2);
            wet = BufRd.ar(2, wobbleBuffer, pr, interpolation: 4);
            ReplaceOut.ar(bus, XFade2.ar(dry, wet, mix * 2 - 1));
        }).add;

        SynthDef(\grainsbitcrush, {
            arg bus, mix = 0.0, rate = 4500, bits = 14, mod_mix = 0;
            var sig = In.ar(bus, 2);
            var mod = LFNoise1.kr(0.25).range(0.4, 1);
            var actualMix = mix * Select.kr(mod_mix, [1.0, LFNoise1.kr(0.25).range(0.0, 1.0)]);
            var bit = LPF.ar(Decimator.ar(sig, Lag.kr(rate, 0.6) * mod, bits), 10000);
            ReplaceOut.ar(bus, XFade2.ar(sig, bit, actualMix * 2 - 1));
        }).add;

        SynthDef(\grainswavefold, {
            arg bus, mix = 0, drive = 0.75, sym = 0;
            var sig = In.ar(bus, 2);
            var pregain = drive.linexp(0, 1, 1, 64);
            var makeup = pregain.pow(-0.8);
            var pre = sig * pregain + sym;
            var folded = LeakDC.ar(sin(pre * (pi/2))) * makeup;
            ReplaceOut.ar(bus, XFade2.ar(sig, folded, mix * 2 - 1));
        }).add;

        SynthDef(\grainsresonator, {
            arg bus, mix = 0.0, decay = 2.0, f1 = 220, f2 = 277, f3 = 330, f4 = 440, f5 = 554, flush = 0;
            var sig, exc, freqs, amps, wet, detune;
            sig = In.ar(bus, 2);
            exc = tanh(sig.sum * 0.15) * (1 - flush);
            freqs = [f1, f2, f3, f4, f5];
            amps = [1.0, 0.9, 0.8, 0.7, 0.6];
            wet = DynKlank.ar(`[freqs, amps, Array.fill(5, decay)], exc);
            wet = tanh(0.05 * wet * decay.pow(-0.75));
            detune = DelayC.ar(wet, 0.02, [0.006, 0.011]);
            wet = wet + detune;
            ReplaceOut.ar(bus, XFade2.ar(sig, wet, mix * 2 - 1));
        }).add;

        SynthDef(\grainsglitch, {
            arg bus, glitch_ratio = 0.0, mix = 1, minLength = 0.075, maxLength = 0.2, reverse = 0, pitch = 0, maxStutters = 5, gate_amt = 1, decay = 0, flush = 0, r1 = 0.5, r2 = 0.7491535, r3 = 1.4983071, r4 = 2;
            var sig, sr, frames, busy, rest, writePos, idle, cool, trig, len, start, ps, dur, on, el, t, rel, pos, fade, env, wet;
            sig = In.ar(bus, 2);
            sr = SampleRate.ir;
            frames = BufFrames.ir(glitchBuffer);
            writePos = Phasor.ar(0, 1, 0, frames);
            BufWr.ar(sig * (1 - flush), glitchBuffer, writePos);
            #busy, rest = LocalIn.kr(2);
            idle = (2 + maxStutters) * (minLength + maxLength) * 0.25 * (1 - glitch_ratio).max(0.01) / glitch_ratio.max(0.0001);
            cool = (idle * 0.5).min(4);
            trig = Dust.kr((idle - cool).reciprocal) * (1 - rest) * (1 - busy);
            len = TRand.kr(minLength, maxLength, trig) * sr;
            start = (Latch.kr(writePos, trig) - len).wrap(0, frames);
            ps = Select.kr(TRand.kr(0, 1, trig) < pitch, [1, Select.kr(TIRand.kr(0, 3, trig), [r1, r2, r3, r4])]);
            dur = (TIRand.kr(2, maxStutters, trig) * len / ps).min(frames - len - (sr * 0.02)) / sr;
            on = Trig1.kr(trig, dur);
            el = Sweep.kr(trig, 1);
            LocalOut.kr([on, Trig1.kr(busy * (1 - on), cool)]);
            t = T2A.ar(trig);
            len = Latch.ar(len, t);
            rel = Phasor.ar(t, ps, 0, len);
            pos = Latch.ar(start, t) + Select.ar(TRand.kr(0, 1, trig) < reverse, [rel, len - rel]);
            fade = (len * gate_amt * 0.25).clip(1, sr * 0.005);
            env = (rel / fade).clip(0, 1).min(((len * gate_amt - rel) / fade).clip(0, 1));
            wet = BufRd.ar(2, glitchBuffer, pos, 1, 2) * env * (1 - (decay * (el / dur.max(0.001)).clip(0, 1)));
            ReplaceOut.ar(bus, LinXFade2.ar(sig, wet, (Lag.kr(on, 0.005) * mix * 2) - 1));
        }).add;

        SynthDef(\grainshaas, {
            arg bus;
            var sig = In.ar(bus, 2);
            ReplaceOut.ar(bus, [sig[0], DelayN.ar(sig[1], 0.05, 0.02)]);
        }).add;

        SynthDef(\grainsrotate, {
            arg bus, rspeed = 0;
            var sig = In.ar(bus, 2);
            ReplaceOut.ar(bus, Rotate2.ar(sig[0], sig[1], LFSaw.kr(rspeed)));
        }).add;

        SynthDef(\grainsbounce, {
            arg buf, bus, xf = 0.05;
            var sig = In.ar(bus, 2);
            var frames = BufFrames.ir(buf);
            var xframes = (xf.clip(0.005, BufDur.ir(buf)) * SampleRate.ir).round;
            var idx = Phasor.ar(0, 1, 0, frames * 4);
            var wpos = Select.ar(idx >= frames, [idx, (idx - frames).min(xframes)]);
            var w = ((idx - frames) / xframes).clip(0, 1);
            var existing = BufRd.ar(2, buf, wpos, loop: 0, interpolation: 1);
            PauseSelf.kr(A2K.kr(idx >= (frames + xframes)));
            BufWr.ar((sig * (w * 0.5pi).cos) + (existing * (w * 0.5pi).sin), buf, wpos, loop: 0);
        }).add;

        SynthDef(\grainsrec, {
            arg buf, inL = 0, inR = 1, gain = 1, run = 0, src = 1, mon = 0, out = 0, gate = 1;
            var l = In.ar(inL, 1) * gain, r = In.ar(inR, 1) * gain;
            var mono = (l + r) * 0.5;
            var sig = [Select.ar(src, [l, mono, l, r]),
                       Select.ar(src, [r, mono, l, r])];
            var fade = EnvGen.kr(Env.asr(0.02, 1, 0.03), gate);
            RecordBuf.ar(sig, buf, recLevel: 1, preLevel: 0, run: run, loop: 0, doneAction: 0);
            SendPeakRMS.kr([l, r], 20, 3, "/grains_rec");
            Out.ar(out, sig * mon * fade);
        }).add;

        SynthDef(\grainsshimmer, {
            arg bus, mix = 0.0, lowpass1 = 13000, hipass1 = 1400, pitchv1 = 0.02, fb1 = 0.0, fbDelay1 = 0.15, shimmer_oct1 = 2, mod_mix = 1, flush = 0;
            var input = In.ar(bus, 2);
            var hpf = HPF.ar(input * (1 - flush), hipass1);
            var pit = PitchShift.ar(hpf, 0.5, shimmer_oct1, pitchv1, 1, mul: 10);
            var fbSig = LocalIn.ar(2);
            var fbClean = fbSig * fb1 * (1 - flush);
            var actualMix = mix * Select.kr(mod_mix, [1.0, LFNoise1.kr(0.25).range(0.0, 1.0)]);
            var modTime;
            pit = LPF.ar((pit + fbClean), lowpass1);
            modTime = fbDelay1 + SinOsc.kr([0.07, 0.09], [0, 0.5pi], 0.5 * 0.004);
            LocalOut.ar(DelayC.ar(pit, 1.0, modTime.clip(0.001, 1.0)).softclip);
            ReplaceOut.ar(bus, input + (pit * actualMix));
        }).add;

        SynthDef(\grainsdelay, {
            arg bus, mix = 0.0, delay = 0.5, fb_amt = 0.3, dhpf = 20, lpf = 20000, w_rate = 0.0, w_depth = 0.0, stereo = 0.2, duck_amt = 0.0, flush = 0;
            var input, local, fb, delayed, wet, combinedMod, lfo2Rate, lfo3Rate;
            var baseLFO, drift, wobble, steps, dryAmp, duck;
            lfo2Rate = w_rate * (1 + LFNoise1.kr(0.13, 0.18));
            lfo3Rate = w_rate * 0.71;
            baseLFO = SinOsc.kr(w_rate * [0.6, 0.63]).sum * 0.5;
            drift = LFNoise2.kr(w_rate * 0.15) * 0.35;
            wobble = SinOsc.kr(lfo2Rate + (drift * 0.6)) * LFNoise2.kr(lfo3Rate * 0.25).range(0.5, 1.2) * 0.25;
            steps = Latch.kr(LFNoise0.kr(w_rate * 6.3), Dust.kr(w_rate * 4.7)) * 0.08;
            combinedMod = w_depth * Mix([baseLFO * 0.4, drift, wobble, steps]);
            input = In.ar(bus, 2);
            local = LocalIn.ar(2);
            fb = LPF.ar(HPF.ar(local, dhpf), lpf);
            fb = (1.35 * (1 - (stereo * 0.35)) * fb_amt * [fb[1], fb[0]]).softclip;
            delayed = DelayC.ar((input + fb) * (1 - flush), 5, Lag.kr(delay, 0.7) + combinedMod);
            wet = Balance2.ar(delayed[0], delayed[1], (SinOsc.kr(delay.max(0.1).reciprocal * 0.5) + (LFNoise2.kr(0.4) * 0.3)) * (stereo * 0.77));
            LocalOut.ar(wet);
            dryAmp = Amplitude.kr(input.sum, 0.005, 0.05);
            duck = LagUD.kr((1 - (dryAmp.sqrt * duck_amt * 6).clip(0, 1)), 0.15, 0.02);
            ReplaceOut.ar(bus, input + (wet * mix * 1.8 * duck));
        }).add;

        SynthDef(\grainstilt, {
            arg bus, tilt = 0;
            var sig = In.ar(bus, 2);
            var g = Lag.kr(tilt, 0.05);
            sig = BLowShelf.ar(sig, 800, 1, g.neg);
            sig = BHiShelf.ar(sig, 800, 1, g);
            ReplaceOut.ar(bus, sig);
        }).add;

        SynthDef(\grainsdimension, {
            arg bus, mix = 0;
            var sig = In.ar(bus, 2);
            var wet, depth = 0.2, rate = 0.6, predelay = 0.025, voice1, voice2, voice3, voice4, wide;
            var chorus = { |input, delayTime, rate, depth| var mod = SinOsc.kr(rate, [0, pi/2]).range(-1, 1) * depth; var delays = delayTime + (mod * 0.02); DelayL.ar(input, 0.05, delays); };
            voice1 = chorus.(sig, predelay * 0.5, rate * 0.99, depth * 0.8);
            voice2 = chorus.(sig, predelay * 0.65, rate * 1.01, depth * 0.9);
            voice3 = chorus.(sig, predelay * 0.85, rate * 0.98, depth * 1.0);
            voice4 = chorus.(sig, predelay * 1.05, rate * 1.02, depth * 0.7);
            wet = [voice1[0] * 0.25 + voice2[0] * 0.25 + voice3[1] * 0.25 + voice4[1] * 0.25, voice1[1] * 0.25 + voice2[1] * 0.25 + voice3[0] * 0.25 + voice4[0] * 0.25];
            wide = wet * 6;
            ReplaceOut.ar(bus, XFade2.ar(sig, wide, mix * 2 - 1));
        }).add;

        [\grainsmain, \grainsmainlim].do({ arg defName, lim;
        SynthDef(defName, { arg bus, out = 0, width = 1;
            var sig = In.ar(bus, 2), m, s;
            m = (sig[0] + sig[1]) * 0.5;
            s = (sig[0] - sig[1]) * 0.5 * width.clip(0, 2);
            sig = [m + s, m - s];
            Out.ar(out, if(lim > 0, { Limiter.ar(sig, 0.95, 0.008) }, { sig }));
        }).add;
        });

        context.server.sync;

        pg = ParGroup.head(context.xg);
        pgv = Array.fill(nv, { ParGroup.head(pg) });
        dg = ParGroup.after(pg);
        vfg = ParGroup.after(dg);
        vfDef = Array.fill(nv, { \grainsvoicedry });
        vfOn = Array.fill(nv, { false });
        vfilt = Array.fill(nv, { arg i;
            Synth.newPaused(\grainsvoicedry,
                [\in, voiceBus[i].index, \out, busMain.index], vfg, 'addToTail');
        });

        fxBitcrush = Synth.newPaused(\grainsbitcrush, [\bus, busMain.index, \mix, 0], context.xg, 'addToTail');
        fxResonator = Synth.newPaused(\grainsresonator, [\bus, busMain.index, \mix, 0], context.xg, 'addToTail');
        fxEq = Synth.newPaused(\grainseq, [\bus, busMain.index], context.xg, 'addToTail');
        fxTilt = Synth.newPaused(\grainstilt, [\bus, busMain.index, \tilt, 0], context.xg, 'addToTail');
        fxWavefold = Synth.newPaused(\grainswavefold, [\bus, busMain.index, \mix, 0], context.xg, 'addToTail');
        fxRingmod = Synth.newPaused(\grainsringmod, [\bus, busMain.index], context.xg, 'addToTail');
        fxShaper = Synth.newPaused(\grainsshaper, [\bus, busMain.index, \mix, 0], context.xg, 'addToTail');
        fxGlitch = Synth.newPaused(\grainsglitch, [\bus, busMain.index, \mix, 0], context.xg, 'addToTail');
        fxTape = Synth.newPaused(\grainstape, [\bus, busMain.index], context.xg, 'addToTail');
        fxReel = Synth.newPaused(\grainsreel, [\bus, busMain.index], context.xg, 'addToTail');
        fxWobble = Synth.newPaused(\grainswobble, [\bus, busMain.index, \mix, 0], context.xg, 'addToTail');
        fxGenloss = Synth.newPaused(\grainsgenloss, [\bus, busMain.index], context.xg, 'addToTail');
        fxSub = Synth.newPaused(\grainssub, [\bus, busMain.index], context.xg, 'addToTail');
        fxSpiral = Synth.newPaused(\grainsspiral, [\bus, busMain.index], context.xg, 'addToTail');
        fxShimmer = Synth.newPaused(\grainsshimmer, [\bus, busMain.index, \mix, 0], context.xg, 'addToTail');
        fxDelay = Synth.newPaused(\grainsdelay, [\bus, busMain.index, \mix, 0], context.xg, 'addToTail');
        fxRotate = Synth.newPaused(\grainsrotate, [\bus, busMain.index, \rspeed, 0], context.xg, 'addToTail');
        fxStChorus = Synth.newPaused(\grainsstchorus, [\bus, busMain.index], context.xg, 'addToTail');
        fxVibe = Synth.newPaused(\grainsvibe, [\bus, busMain.index], context.xg, 'addToTail');
        fxDimension = Synth.newPaused(\grainsdimension, [\bus, busMain.index, \mix, 0], context.xg, 'addToTail');
        fxHaas = Synth.newPaused(\grainshaas, [\bus, busMain.index], context.xg, 'addToTail');
        fxOtt = Synth.newPaused(\grainsott, [\bus, busMain.index], context.xg, 'addToTail');
        fxMain = Synth.new(\grainsmain, [\bus, busMain.index, \out, context.out_b.index], context.xg, 'addToTail');

        reportRate = 30;
        this.setReport(nv * nlMax);

        [4, 5, 6, 10, 14].do({ arg pairs;
            this.addCommand(("set_win" ++ pairs).asSymbol,
                "i" ++ String.fill(pairs * 2, { $f }),
                { arg msg; this.setWin(msg, pairs) });
        });
        this.addCommand("set_all", "sf", { arg msg; this.setAllVoices(msg[1].asSymbol, msg[2]); });
        this.addCommand("set_one", "isf", { arg msg; this.setVoice(msg[1].asInteger, msg[2].asSymbol, msg[3]); });
        this.addCommand("clear_param", "is", { arg msg; this.clearParam(msg[1].asInteger, msg[2].asSymbol); });
        this.addCommand("reseed", "", { this.reseedAll });
        this.addCommand("quality", "i", { arg msg; this.setQuality(msg[1].asInteger) });
        this.addCommand("reseed_one", "i", { arg msg; this.reseedVoice(msg[1].asInteger) });
        this.addCommand("active", "ii", { arg msg; var i = msg[1].asInteger; var on = msg[2] > 0; if((i >= 0) and: { i < nv } and: { on != actives[i] }, { actives[i] = on; if(on, { if(buffers[i] !== silent, { this.startVoice(i) }); }, { this.stopVoice(i); this.clearState(i); }); }); });
        this.addCommand("layers", "ii", { arg msg; var i = msg[1].asInteger; if((i >= 0) and: { i < nv }, { this.setLayers(i, msg[2].asInteger); }); });
        this.addCommand("clear", "i", { arg msg; var i = msg[1].asInteger; if((i >= 0) and: { i < nv }, { var old = buffers[i]; loadTok[i] = loadTok[i] + 1; buffers[i] = silent; nls[i] = 1; this.stopVoice(i); this.clearState(i); if(old.notNil and: { old !== silent }, { fork { 2.5.wait; old.free }; }); }); });
        this.addCommand("read", "isfff", { arg msg; this.readChunk(msg[1].asInteger, msg[2].asString, msg[3], msg[4], msg[5]); });
        this.addCommand("move", "ii", { arg msg; this.moveVoice(msg[1].asInteger, msg[2].asInteger); });
        this.addCommand("report_rate", "f", { arg msg; reportRate = msg[1]; if(reporter.notNil, { reporter.set(\rate, reportRate) }); });
        this.addCommand("report_geom", "ii", { arg msg; this.setGeom(msg[1].asInteger, msg[2].asInteger); });
        [
            [fxDelay, \d_time, \delay, \d_fb, \fb_amt, \d_hpf, \dhpf, \d_lpf, \lpf, \d_wrate, \w_rate, \d_stereo, \stereo, \d_duck, \duck_amt],
            [fxShimmer, \sh_oct, \shimmer_oct1, \sh_lowpass, \lowpass1, \sh_hipass, \hipass1, \sh_pitchv, \pitchv1, \sh_fb, \fb1, \sh_fbdelay, \fbDelay1, \sh_mod, \mod_mix],
            [fxWobble, \wobble_amp, \wobble_amp, \wobble_rpm, \wobble_rpm, \flutter_amp, \flutter_amp, \flutter_freq, \flutter_freq, \flutter_var, \flutter_var],
            [fxBitcrush, \bc_mod, \mod_mix, \bc_rate, \rate, \bc_bits, \bits],
            [fxResonator, \reso_decay, \decay],
            [fxWavefold, \wf_drive, \drive, \wf_sym, \sym],
            [fxGlitch, \gl_min, \minLength, \gl_max, \maxLength, \gl_stutters, \maxStutters, \gl_rev, \reverse, \gl_pitch, \pitch, \gl_gate, \gate_amt, \gl_decay, \decay],
            [fxRingmod, \ringmod_rate, \rate, \ringmod_sweep, \sweep],
            [fxSpiral, \spiral_bpm, \bpm, \spiral_div, \div, \spiral_feedback, \feedback, \spiral_rise, \rise, \spiral_glide, \glide, \spiral_span, \span, \spiral_tone, \tone],
            [fxSub, \sub_detune, \detune],
            [fxVibe, \vibe_drift, \drift]
        ].do({ arg row; var syn = row[0]; row.drop(1).pairsDo({ arg cmd, key; this.addCommand(cmd, "f", { arg msg; syn.set(key, msg[1]) }) }) });
        this.addCommand(\d_wdepth, "f", { arg msg; fxDelay.set(\w_depth, msg[1] / 100); });
        this.addCommand("d_mix", "f", { arg msg; fxDelay.set(\mix, msg[1]); this.fxRun(fxDelay, msg[1] > 0, 5.1); });
        this.addCommand("sh_mix", "f", { arg msg; fxShimmer.set(\mix, msg[1]); this.fxRun(fxShimmer, msg[1] > 0, 1.6); });
        this.addCommand("tilt", "f", { arg msg; fxTilt.set(\tilt, msg[1]); fxTilt.run(msg[1] != 0); });
        this.addCommand("dimension_mix", "f", { arg msg; fxDimension.set(\mix, msg[1]); fxDimension.run(msg[1] > 0); });
        this.addCommand("m_width", "f", { arg msg; mainWidth = msg[1]; fxMain.set(\width, msg[1]) });
        this.addCommand("limiter", "i", { arg msg; this.setLimiter(msg[1] > 0) });
        this.addCommand("eq_low", "f", { arg msg; eqLow = msg[1]; fxEq.set(\low, msg[1]); this.updateEq });
        this.addCommand("eq_mid", "f", { arg msg; eqMid = msg[1]; fxEq.set(\mid, msg[1]); this.updateEq });
        this.addCommand("eq_high", "f", { arg msg; eqHigh = msg[1]; fxEq.set(\high, msg[1]); this.updateEq });
        this.addCommand("tape_mix", "f", { arg msg; fxTape.run(msg[1] > 0) });
        this.addCommand("shaper_mix", "f", { arg msg; fxShaper.set(\mix, msg[1]); fxShaper.run(msg[1] > 0) });
        this.addCommand("wobble_mix", "f", { arg msg; fxWobble.set(\mix, msg[1]); this.fxRun(fxWobble, msg[1] > 0, 0.3) });
        this.addCommand("haas", "i", { arg msg; fxHaas.run(msg[1] > 0) });
        this.addCommand("rspeed", "f", { arg msg; fxRotate.set(\rspeed, msg[1]); fxRotate.run(msg[1] > 0) });
        this.addCommand("bc_mix", "f", { arg msg; fxBitcrush.set(\mix, msg[1]); fxBitcrush.run(msg[1] > 0) });
        this.addCommand("reso_mix", "f", { arg msg; fxResonator.set(\mix, msg[1]); this.fxRun(fxResonator, msg[1] > 0, 5.1) });
        this.addCommand("reso_freqs", "fffff", { arg msg; fxResonator.set(\f1, msg[1], \f2, msg[2], \f3, msg[3], \f4, msg[4], \f5, msg[5]) });
        this.addCommand("wf_mix", "f", { arg msg; fxWavefold.set(\mix, msg[1]); fxWavefold.run(msg[1] > 0) });
        this.addCommand("gl_ratio", "f", { arg msg; glRatio = msg[1]; fxGlitch.set(\glitch_ratio, msg[1]); this.updateGlitch });
        this.addCommand("gl_ratios", "ffff", { arg msg; fxGlitch.set(\r1, msg[1], \r2, msg[2], \r3, msg[3], \r4, msg[4]) });
        this.addCommand("gl_mix", "f", { arg msg; glMix = msg[1]; fxGlitch.set(\mix, msg[1]); this.updateGlitch });
        this.addCommand("ringmod_mix", "f", { arg msg; fxRingmod.set(\mix, msg[1]); fxRingmod.run(msg[1] > 0) });
        this.addCommand("stchorus_mix", "f", { arg msg; fxStChorus.set(\mix, msg[1]); fxStChorus.run(msg[1] > 0) });
        this.addCommand("vibe_mix", "f", { arg msg; fxVibe.set(\mix, msg[1]); fxVibe.run(msg[1] > 0) });
        this.addCommand("spiral_mix", "f", { arg msg; fxSpiral.set(\mix, msg[1]); this.fxRun(fxSpiral, msg[1] > 0, 2.8) });
        this.addCommand("genloss_mix", "f", { arg msg; fxGenloss.set(\mix, msg[1]); fxGenloss.run(msg[1] > 0) });
        this.addCommand("sub_mix", "f", { arg msg; fxSub.set(\mix, msg[1]); fxSub.run(msg[1] > 0) });
        this.addCommand("reel_mix", "f", { arg msg; fxReel.set(\mix, msg[1]); fxReel.run(msg[1] > 0) });
        this.addCommand("ott_mix", "f", { arg msg; fxOtt.set(\mix, msg[1]); fxOtt.run(msg[1] > 0) });
        this.addCommand("bounce", "fsf", { arg msg; this.bounce(msg[1], msg[2].asString, msg[3]) });
        this.addCommand("rec_start", "sfffff", { arg msg; this.recStart(msg[1].asString, msg[2], msg[3], msg[4], msg[5], msg[6]) });
        this.addCommand("rec_stop", "i", { arg msg; this.recStop(msg[1].asInteger) });

        oState = OSCFunc({ |msg|
            var n = msg.size - 3;
            if(n > 0, {
                if(stateMsg.isNil or: { stateMsg.size != (n + 2) }, {
                    stateMsg = Array.newClear(n + 2);
                    stateMsg[0] = "/grains/state";
                });
                stateMsg[1] = curStride;
                n.do({ arg k; stateMsg[k + 2] = msg[k + 3] });
                nornsAddr.sendMsg(*stateMsg);
            });
        }, '/grains_state', context.server.addr);
        oRec = OSCFunc({ |msg| nornsAddr.sendMsg("/grains/rec_level", msg[3], msg[5]); }, '/grains_rec', context.server.addr);
    }

    free {
        recOn = false;
        if(oState.notNil, { oState.free });
        if(oRec.notNil, { oRec.free });
        if(recSyn.notNil, { recSyn.free });
        if(recBuf.notNil, { recBuf.free });
        voices.do({ arg row; row.do({ arg x; if(x.notNil, { x.free }) }) });
        [reporter, fxMain, fxDelay, fxShimmer, fxTilt, fxDimension, fxEq, fxTape,
         fxShaper, fxWobble, fxBitcrush, fxWavefold, fxResonator, fxGlitch,
         fxHaas, fxRotate, fxRingmod, fxStChorus, fxVibe, fxSpiral, fxGenloss, fxSub, fxReel, fxOtt, vfg, dg].do({ arg x; if(x.notNil, { x.free }); });
        if(pgv.notNil, { pgv.do({ arg g; if(g.notNil, { g.free }) }) });
        if(pg.notNil, { pg.free });
        buffers.do({ arg b; if(b.notNil and: { b !== silent }, { b.free }) });
        [wobbleBuffer, glitchBuffer, spiralBuffer, bufSine].do({ arg b; if(b.notNil, { b.free }) });
        if(silent.notNil, { silent.free });
        if(voiceBus.notNil, { voiceBus.do({ arg b; if(b.notNil, { b.free }) }) });
        [stateBus, busMain].do({ arg b; if(b.notNil, { b.free }) });
    }
}
