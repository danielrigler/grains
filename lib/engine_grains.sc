Engine_grains : CroneEngine {

    classvar <nv = 6;
    classvar <nlMax = 14;
    classvar <wfCols = 128;
    classvar <minFrames = 4096;
    classvar <relLeave = 1.2;
    classvar <reportChunk = 4;
    classvar <recDir = "/home/we/dust/audio/grains/";
    classvar <recMinDur = 0.1;

    var <buffers, <silent, <voices, pg;
    var dying, dyingUntil;
    var stateBus, reporter, reportRate, oState, nornsAddr;
    var curStride, reportSlots, trashIndex, curReportK = -1;
    var busMain, fxMain, fxDelay, fxShimmer, fxTilt, fxDimension;
    var fxEq, fxTape, fxShaper, fxWobble, fxBitcrush, fxWavefold;
    var fxResonator, fxGlitch, fxHaas, fxRotate;
    var wobbleBuffer, glitchBuffer, bufSine;
    var eqLow = 0, eqMid = 0, eqHigh = 0, glRatio = 0, glMix = 1;
    var vparams, gparams, nls, actives, wins, loadTok, loadDone;
    var recBuf, recSyn, recPath, recNorm = 0, recBegan, recOn = false, oRec, inL = 0, inR = 1;

    *new { arg context, doneCallback; ^super.new(context, doneCallback); }

    updateEq { fxEq.run((eqLow != 0) || (eqMid != 0) || (eqHigh != 0)) }
    updateGlitch { fxGlitch.run((glRatio > 0) && (glMix > 0)) }

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

    retire { arg s, rel = 0.3; if(s.notNil, { s.set(\rel, rel, \gate, 0) }) }

    retireSlot { arg i, ly, rel;
        var s = voices[i][ly];
        if(s.notNil, {
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
        ^s
    }

    stopVoice { arg i;
        nlMax.do({ arg ly; this.retireSlot(i, ly, relLeave) });
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
        nv.do({ arg i;
            nlMax.do({ arg ly;
                var s = voices[i][ly];
                if(s.notNil, { s.set(*this.seeds) });
            });
        });
    }

    reseedVoice { arg i;
        if((i >= 0) and: { i < nv }, {
            nlMax.do({ arg ly;
                var s = voices[i][ly];
                if(s.notNil, { s.set(*this.seeds) });
            });
        });
    }

    layerArgs { arg i, ly;
        var base = [\bus, busMain.index, \buf, buffers[i]];
        gparams.keysValuesDo({ arg k, v; base = base ++ [k, v] });
        vparams[i].keysValuesDo({ arg k, v; base = base ++ [k, v] });
        ^base ++ this.seeds ++ [
            \posStart, wins[((i * nlMax) + ly) * 2],
            \posEnd,   wins[(((i * nlMax) + ly) * 2) + 1],
            \statebus, this.stateIndex(i, ly)
        ]
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
        voices[i][ly] = Synth.head(pg, \grainsloop, this.layerArgs(i, ly));
    }

    startVoice { arg i;
        if(actives[i].not, { ^this.stopVoice(i) });
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
        nlMax.do({ arg ly;
            var s = voices[i][ly];
            if(s.notNil, { s.set(key, val) });
        });
    }

    clearParam { arg i, key;
        var g;
        vparams[i].removeAt(key);
        g = gparams.at(key);
        if(g.notNil, {
            nlMax.do({ arg ly;
                var s = voices[i][ly];
                if(s.notNil, { s.set(key, g) });
            });
        });
    }

    setAllVoices { arg key, val;
        gparams.put(key, val);
        nv.do({ arg i;
            nlMax.do({ arg ly;
                var s = voices[i][ly];
                if(s.notNil, { s.set(key, val) });
            });
        });
    }

    readFailed { arg i, token;
        if(token.notNil and: { token != loadTok[i] }, { ^this });
        loadTok[i] = loadTok[i] + 1;
        nornsAddr.sendMsg("/grains/fail", i);
    }

    readChunk { arg i, path, chunkDur = 12, randomStart = 1, startSec = 0;
        var token;
        if(File.exists(path).not, { ^this.readFailed(i) });
        loadTok[i] = loadTok[i] + 1;
        token = loadTok[i];
        fork {
            var sf = SoundFile.openRead(path.asString);
            var frames, sr, start, num;
            if(sf.isNil, { this.readFailed(i, token) }, {
                frames = sf.numFrames;
                sr = sf.sampleRate;
                sf.close;
                if((frames > minFrames) and: { sr > 0 }, {
                    num = min(frames, (chunkDur * sr).asInteger).max(minFrames);
                    num = min(num, frames);
                    start = if((randomStart > 0) and: { frames > num }, {
                        (frames - num).rand
                    }, {
                        (startSec * sr).asInteger.clip(0, max(frames - num, 0))
                    });
                    Buffer.readChannel(context.server, path, start, num, [0], { |b|
                        var old;
                        if(b.isNil or: { token != loadTok[i] }, {
                            if(b.isNil, { this.readFailed(i, token) }, { b.free });
                        }, {
                            old = buffers[i];
                            buffers[i] = b;
                            loadDone[i] = token;
                            this.startVoice(i);
                            if(old.notNil and: { old !== silent }, {
                                fork { 2.5.wait; old.free };
                            });
                        });
                    });
                    this.sendWaveform(i, path, start, num, token);
                    fork { 4.0.wait;
                        if((token == loadTok[i]) and: { loadDone[i] != token },
                           { this.readFailed(i, token) });
                    };
                }, {
                    this.readFailed(i, token);
                });
            });
        };
    }

    sendWaveform { arg i, path, start, num, token;
        fork {
            if(token == loadTok[i], {
                var sf = SoundFile.openRead(path.asString);
                if(sf.isNil, { this.readFailed(i, token) }, {
                    var ch = max(sf.numChannels, 1);
                    var sr = max(sf.sampleRate, 1);
                    var block = min(1024, max(1, num div: wfCols));
                    var peaks = Array.fill(wfCols, { arg c;
                        var raw = FloatArray.newClear(block * ch);
                        var mx = 0, n;
                        sf.seek(start + (num * c div: wfCols), 0);
                        sf.readData(raw);
                        n = raw.size div: ch;
                        n.do({ arg k;
                            var v = raw[k * ch].abs;
                            if(v > mx, { mx = v });
                        });
                        mx
                    });
                    sf.close;
                    if(token == loadTok[i], {
                        nornsAddr.sendMsg(*(["/grains/waveform", i] ++ peaks ++ [start / sr]));
                    });
                });
            });
        };
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
        loadDone[dst] = loadTok[dst];
        vparams[dst] = vparams[src].copy;

        actives[dst] = actives[src];

        buffers[src] = silent;
        nls[src] = 1;
        loadDone[src] = loadTok[src];
        vparams[src] = Dictionary.new;
        actives[src] = false;

        this.stopVoice(src);
        this.clearState(src);

        if(old.notNil and: { old !== silent }, { fork { 2.5.wait; old.free }; });

        this.clearState(dst);
        if(b === silent, {
            this.stopVoice(dst);
        }, {
            this.startVoice(dst);
        });
    }

    alloc {
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

        silent = Buffer.alloc(context.server, context.server.sampleRate.asInteger, 1);
        buffers = Array.fill(nv, { silent });
        voices = Array.fill(nv, { Array.fill(nlMax, { nil }) });
        dying = Array.fill(nv, { Array.fill(nlMax, { nil }) });
        dyingUntil = Array.fill(nv, { Array.fill(nlMax, { 0 }) });
        vparams = Array.fill(nv, { Dictionary.new });
        gparams = Dictionary.new;
        nls = Array.fill(nv, { 1 });
        actives = Array.fill(nv, { false });
        wins = Array.fill(nv * nlMax * 2, { arg k; (k % 2) });
        loadTok = Array.fill(nv, { 0 });
        loadDone = Array.fill(nv, { -1 });

        stateBus = Bus.control(context.server, (nv * nlMax) + 1);
        trashIndex = stateBus.index + (nv * nlMax);
        curStride = nlMax;
        reportSlots = ((nv * nlMax) / reportChunk).ceil.asInteger;
        busMain = Bus.audio(context.server, 2);

        bufSine = Buffer.alloc(context.server, 4096, 1);
        bufSine.sine2([2], [0.5], false);
        wobbleBuffer = Buffer.alloc(context.server, context.server.sampleRate * 5, 2);
        glitchBuffer = Buffer.alloc(context.server, context.server.sampleRate * 1, 2);

        context.server.sync;

        SynthDef(\grainsloop, {
            arg bus, buf, statebus = 0, posStart = 0, posEnd = 1, vamp = 0.25, mrate = 1, prate = 1, gate = 1, rel = 1, rateSlew = 1.5, vrate = 1, weight1 = 14, weight2 = 8, weight3 = 3, weight4 = 6, weight5 = 4, lrate1 = 1, lrate2 = 0.5, lrate3 = 4, lrate4 = 2, lrate5 = 0.25, lamp1 = 1, lamp2 = 1.5849, lamp3 = 0.1259, lamp4 = 0.3981, lamp5 = 1.2589, revprob = 0.5, cutoff = 15000, res = 0.3, hpf = 25, panwidth = 0.5, ampfloor = 0.25, kTune = 3, kDir = 6, kAmp = 4.5, kPan = 8, phAmp = 0, phPan = 0, lagAmp = 0.4, vampLag = 1;

            var amp, frames, idx, tuneTrig;
            var lfoRate, lfoAmp2, lfoForward, lfoAmp, lfoPan, rate, rateSign;
            var pStart, pEnd, span, tiny, edge, switch, pos1, pos2, snd1, snd2, posK, resetTo;
            var snd, volume, boot;
            var xfk, xfr, settled, outside, dirNow;
            var xfTime = 0.03, chkRate = 25;

            amp    = Lag.kr(vamp, vampLag);
            frames = BufFrames.kr(buf).max(4096);

            boot = Impulse.kr(0);
            tuneTrig = boot + Dust.kr(prate / kTune);
            idx = TWindex.kr(tuneTrig, [weight1, weight2, weight3, weight4, weight5], 1);
            lfoRate = vrate * Select.kr(idx, [lrate1, lrate2, lrate3, lrate4, lrate5]);
            lfoAmp2 = Select.kr(idx, [lamp1, lamp2, lamp3, lamp4, lamp5]);

            lfoForward = Demand.kr(Impulse.kr(mrate / kDir), 0, Dwrand([1, 0], [1 - revprob, revprob], inf));
            lfoAmp = SinOsc.kr(mrate / kAmp, phAmp).range(ampfloor.clip(0, 1), 1);
            lfoPan = SinOsc.kr(mrate / kPan, phPan).range(-1, 1) * panwidth.clip(0, 1);

            rateSign = (2 * lfoForward) - 1;
            rate = Lag.kr(lfoRate * rateSign, rateSlew.max(0.001)) * BufRateScale.kr(buf);

            span    = (frames * 0.04).min(2048);
            tiny    = (frames * 0.005).min(256);
            edge    = ((SampleRate.ir * 0.2).min(frames * 0.06)).max(tiny);
            pStart  = Clip.kr(posStart * frames, edge, frames - span - edge);
            pEnd    = Clip.kr(posEnd * frames, pStart + span, frames - edge);

            switch = ToggleFF.kr(LocalIn.kr(1));

            dirNow  = rate > 0;
            resetTo = pEnd + (dirNow * (pStart - pEnd));

            pos1 = Phasor.ar(trig: 1 - switch, rate: rate, start: 0, end: frames, resetPos: resetTo);
            snd1 = BufRd.ar(1, buf, pos1, 1.0, 4);
            pos2 = Phasor.ar(trig: switch, rate: rate, start: 0, end: frames, resetPos: resetTo);
            snd2 = BufRd.ar(1, buf, pos2, 1.0, 4);

            posK = Select.kr(switch, [A2K.kr(pos1), A2K.kr(pos2)]);

            xfr     = Slew.kr(switch, 1 / xfTime, 1 / xfTime);
            xfk     = xfr * xfr * (3 - (2 * xfr));
            settled = (xfr - switch).abs < 1e-4;
            outside = (posK > pEnd) + (posK < pStart);

            LocalOut.kr(Changed.kr(Stepper.kr(Impulse.kr(chkRate), 0, 0, 1000000000, outside * settled)));

            snd = XFade2.ar(snd1, snd2, (xfk * 2) - 1);

            volume = lfoAmp * EnvGen.kr(Env.new([0, 1], [Rand(0.5, 4)], 4));
            volume = volume * EnvGen.kr(Env.adsr(1, 1, 1, rel), gate + boot, doneAction: 2);
            volume = volume * EnvGen.kr(Env.adsr(Rand(1, 3), 1, 1, Rand(1, 3)), 1);
            volume = volume * 2 * amp * Lag.kr(lfoAmp2, lagAmp);

            snd = HPF.ar(snd, Lag.kr(hpf, 0.1));
            snd = RLPF.ar(snd, Lag.kr(cutoff, 0.1), res);

            snd = Pan2.ar(snd, lfoPan, volume);

            Out.kr(statebus, posK / frames);
            Out.ar(bus, snd);
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
                arg bus, mix = 0.0;
                var orig = In.ar(bus, 2);
                var wet = AnalogTape.ar(orig, 0.9, 0.9, 0.9, 0, 0);
                ReplaceOut.ar(bus, XFade2.ar(orig, wet, mix * 2 - 1));
        }).add;

        SynthDef(\grainsshaper, {
            arg bus, mix = 0;
            var orig = In.ar(bus, 2);
            var shaped = Shaper.ar(bufSine, orig * 1.5);
            ReplaceOut.ar(bus, SelectX.ar(mix, [orig, shaped]));
        }).add;

        SynthDef(\grainswobble, {
            arg bus, mix = 0.0, wobble_amp = 0.05, wobble_rpm = 33, flutter_amp = 0.03, flutter_freq = 6, flutter_var = 2;
            var pr, pw, rate, wet, flutter, wow, dry;
            dry = In.ar(bus, 2);
            wow = wobble_amp * SinOsc.kr(wobble_rpm / 60, mul: 0.2);
            flutter = flutter_amp * SinOsc.kr(flutter_freq + LFNoise2.kr(flutter_var), mul: 0.1);
            rate = 1 + (wow + flutter);
            pw = Phasor.ar(0, BufRateScale.ir(wobbleBuffer), 0, BufFrames.ir(wobbleBuffer));
            BufWr.ar(dry, wobbleBuffer, pw);
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
            arg bus, mix = 0.0, decay = 2.0, f1 = 220, f2 = 277, f3 = 330, f4 = 440, f5 = 554;
            var sig, exc, freqs, amps, wet, detune;
            sig = In.ar(bus, 2);
            exc = tanh(sig.sum * 0.15);
            freqs = [f1, f2, f3, f4, f5];
            amps = [1.0, 0.9, 0.8, 0.7, 0.6];
            wet = DynKlank.ar(`[freqs, amps, Array.fill(5, decay)], exc);
            wet = tanh(0.05 * wet * decay.pow(-0.75));
            detune = DelayC.ar(wet, 0.02, [0.006, 0.011]);
            wet = wet + detune;
            ReplaceOut.ar(bus, XFade2.ar(sig, wet, mix * 2 - 1));
        }).add;

        SynthDef(\grainsglitch, {
            arg bus, probability = 5, glitch_ratio = 0.0, mix = 1, minLength = 0.075, maxLength = 0.2, reverse = 0, pitch = 0, maxStutters = 5;
            var sig, bufFrames, writePos, rawTrigOn, trigOn, earlyOff, trigOff, isGlitching, isGlitching_fb, capturePos, chunkLength, chunkStart, stutterCount, autoOff, pitchShift, isReverse, relPos, bufReadPos, wet_raw, wet, fadeSamples, startRamp, endRamp, loopEnv, sr;
            sig = In.ar(bus, 2);
            sr = SampleRate.ir;
            bufFrames = BufFrames.ir(glitchBuffer);
            fadeSamples = sr * 0.06;
            writePos = Phasor.ar(0, 1, 0, bufFrames);
            BufWr.ar(sig, glitchBuffer, writePos);
            isGlitching_fb = LocalIn.kr(1);
            rawTrigOn = Dust.kr(probability * glitch_ratio);
            trigOn = rawTrigOn * (1 - isGlitching_fb);
            capturePos = Latch.kr(writePos, trigOn);
            chunkLength = TRand.kr(minLength * sr, maxLength * sr, trigOn);
            stutterCount = TIRand.kr(2, maxStutters, trigOn);
            isReverse = TRand.kr(0, 1, trigOn) < reverse;
            pitchShift = 1.0 + ((TRand.kr(0, 1, trigOn) < pitch) * (Select.kr(TIRand.kr(0, 3, trigOn), [0.707, 0.841, 1.189, 1.414]) - 1.0));
            chunkStart = (capturePos - chunkLength).wrap(0, bufFrames - 1);
            autoOff = TDelay.kr(trigOn, stutterCount * (chunkLength / sr) / pitchShift);
            earlyOff = Dust.kr(probability * (1.0 - glitch_ratio).max(0.001)) * isGlitching_fb;
            trigOff = earlyOff + autoOff;
            isGlitching = SetResetFF.kr(trigOn, trigOff);
            LocalOut.kr(isGlitching);
            relPos = Phasor.ar(trigOn, pitchShift, 0, chunkLength, 0);
            bufReadPos = chunkStart + Select.ar(isReverse, [relPos, chunkLength - relPos]);
            wet_raw = BufRd.ar(2, glitchBuffer, bufReadPos, loop: 1, interpolation: 2);
            startRamp = (relPos / fadeSamples).clip(0, 1);
            endRamp = ((chunkLength - relPos) / fadeSamples).clip(0, 1);
            loopEnv = startRamp.min(endRamp);
            wet = wet_raw * 2 * loopEnv;
            ReplaceOut.ar(bus, LinXFade2.ar(sig, wet, (isGlitching * mix * 2) - 1));
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
            arg bus, mix = 0.0, lowpass1 = 13000, hipass1 = 1400, pitchv1 = 0.02, fb1 = 0.0, fbDelay1 = 0.15, shimmer_oct1 = 2, mod_mix = 1;
            var input = In.ar(bus, 2);
            var hpf = HPF.ar(input, hipass1);
            var pit = PitchShift.ar(hpf, 0.5, shimmer_oct1, pitchv1, 1, mul: 10);
            var fbSig = LocalIn.ar(2);
            var fbClean = fbSig * fb1;
            var actualMix = mix * Select.kr(mod_mix, [1.0, LFNoise1.kr(0.25).range(0.0, 1.0)]);
            var modTime;
            pit = LPF.ar((pit + fbClean), lowpass1);
            modTime = fbDelay1 + SinOsc.kr([0.07, 0.09], [0, 0.5pi], 0.5 * 0.004);
            LocalOut.ar(DelayC.ar(pit, 1.0, modTime.clip(0.001, 1.0)).softclip);
            ReplaceOut.ar(bus, input + (pit * actualMix));
        }).add;

        SynthDef(\grainsdelay, {
            arg bus, mix = 0.0, delay = 0.5, fb_amt = 0.3, dhpf = 20, lpf = 20000, w_rate = 0.0, w_depth = 0.0, stereo = 0.2, duck_amt = 0.0;
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
            delayed = DelayC.ar(input + fb, 5, Lag.kr(delay, 0.7) + combinedMod);
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
            var chorus = { |input, delayTime, rate, depth| var mod = SinOsc.kr(rate, [0, pi/2]).range(-1, 1) * depth; var delays = delayTime + (mod * 0.02); DelayC.ar(input, 0.05, delays); };
            voice1 = chorus.(sig, predelay * 0.5, rate * 0.99, depth * 0.8);
            voice2 = chorus.(sig, predelay * 0.65, rate * 1.01, depth * 0.9);
            voice3 = chorus.(sig, predelay * 0.85, rate * 0.98, depth * 1.0);
            voice4 = chorus.(sig, predelay * 1.05, rate * 1.02, depth * 0.7);
            wet = [voice1[0] * 0.25 + voice2[0] * 0.25 + voice3[1] * 0.25 + voice4[1] * 0.25, voice1[1] * 0.25 + voice2[1] * 0.25 + voice3[0] * 0.25 + voice4[0] * 0.25];
            wide = wet * 8;
            ReplaceOut.ar(bus, XFade2.ar(sig, wide, mix * 2 - 1));
        }).add;

        SynthDef(\grainsmain, { arg bus, out = 0, width = 1, ceiling = 0.95;
            var sig = In.ar(bus, 2), m, s;
            m = (sig[0] + sig[1]) * 0.5;
            s = (sig[0] - sig[1]) * 0.5 * width.clip(0, 2);
            sig = [m + s, m - s];
            Out.ar(out, Limiter.ar(sig, ceiling.clip(0.1, 1.0), 0.008));
        }).add;

        context.server.sync;

        pg = ParGroup.head(context.xg);

        fxEq = Synth.newPaused(\grainseq, [\bus, busMain.index], context.xg, 'addToTail');
        fxTilt = Synth.newPaused(\grainstilt, [\bus, busMain.index, \tilt, 0], context.xg, 'addToTail');
        fxBitcrush = Synth.newPaused(\grainsbitcrush, [\bus, busMain.index, \mix, 0], context.xg, 'addToTail');
        fxResonator = Synth.newPaused(\grainsresonator, [\bus, busMain.index, \mix, 0], context.xg, 'addToTail');
        fxWavefold = Synth.newPaused(\grainswavefold, [\bus, busMain.index, \mix, 0], context.xg, 'addToTail');
        fxShaper = Synth.newPaused(\grainsshaper, [\bus, busMain.index, \mix, 0], context.xg, 'addToTail');
        fxGlitch = Synth.newPaused(\grainsglitch, [\bus, busMain.index, \mix, 0], context.xg, 'addToTail');
        fxTape = Synth.newPaused(\grainstape, [\bus, busMain.index, \mix, 0], context.xg, 'addToTail');
        fxWobble = Synth.newPaused(\grainswobble, [\bus, busMain.index, \mix, 0], context.xg, 'addToTail');
        fxShimmer = Synth.newPaused(\grainsshimmer, [\bus, busMain.index, \mix, 0], context.xg, 'addToTail');
        fxDelay = Synth.newPaused(\grainsdelay, [\bus, busMain.index, \mix, 0], context.xg, 'addToTail');
        fxRotate = Synth.newPaused(\grainsrotate, [\bus, busMain.index, \rspeed, 0], context.xg, 'addToTail');
        fxDimension = Synth.newPaused(\grainsdimension, [\bus, busMain.index, \mix, 0], context.xg, 'addToTail');
        fxHaas = Synth.newPaused(\grainshaas, [\bus, busMain.index], context.xg, 'addToTail');
        fxMain = Synth.new(\grainsmain, [\bus, busMain.index, \out, context.out_b.index], context.xg, 'addToTail');

        reportRate = 30;
        this.setReport(nv * nlMax);

        this.addCommand("set_win", "iffffffffffffffffffffffffffff", { arg msg; var i = msg[1].asInteger; if((i >= 0) and: { i < nv }, { curStride.do({ arg ly; var s = voices[i][ly]; var a = msg[(ly * 2) + 2], b = msg[(ly * 2) + 3]; if(a.notNil and: { b.notNil }, { wins[((i * nlMax) + ly) * 2] = a; wins[(((i * nlMax) + ly) * 2) + 1] = b; if(s.notNil, { s.set(\posStart, a, \posEnd, b) }); }); }); }); });
        this.addCommand("set_all", "sf", { arg msg; this.setAllVoices(msg[1].asSymbol, msg[2]); });
        this.addCommand("set_one", "isf", { arg msg; this.setVoice(msg[1].asInteger, msg[2].asSymbol, msg[3]); });
        this.addCommand("clear_param", "is", { arg msg; this.clearParam(msg[1].asInteger, msg[2].asSymbol); });
        this.addCommand("reseed", "", { this.reseedAll });
        this.addCommand("reseed_one", "i", { arg msg; this.reseedVoice(msg[1].asInteger) });
        this.addCommand("active", "ii", { arg msg; var i = msg[1].asInteger; var on = msg[2] > 0; if((i >= 0) and: { i < nv } and: { on != actives[i] }, { actives[i] = on; if(on, { if(buffers[i] !== silent, { this.startVoice(i) }); }, { this.stopVoice(i); this.clearState(i); }); }); });
        this.addCommand("layers", "ii", { arg msg; var i = msg[1].asInteger; if((i >= 0) and: { i < nv }, { this.setLayers(i, msg[2].asInteger); }); });
        this.addCommand("clear", "i", { arg msg; var i = msg[1].asInteger; if((i >= 0) and: { i < nv }, { var old = buffers[i]; loadTok[i] = loadTok[i] + 1; buffers[i] = silent; nls[i] = 1; this.stopVoice(i); this.clearState(i); if(old.notNil and: { old !== silent }, { fork { 2.5.wait; old.free }; }); }); });
        this.addCommand("read", "isfff", { arg msg; this.readChunk(msg[1].asInteger, msg[2].asString, msg[3], msg[4], msg[5]); });
        this.addCommand("move", "ii", { arg msg; this.moveVoice(msg[1].asInteger, msg[2].asInteger); });
        this.addCommand("report_rate", "f", { arg msg; reportRate = msg[1]; if(reporter.notNil, { reporter.set(\rate, reportRate) }); });
        this.addCommand("report_geom", "ii", { arg msg; this.setGeom(msg[1].asInteger, msg[2].asInteger); });
        this.addCommand(\d_time, "f", { arg msg; fxDelay.set(\delay, msg[1]) });
        this.addCommand(\d_fb, "f", { arg msg; fxDelay.set(\fb_amt, msg[1]) });
        this.addCommand(\d_hpf, "f", { arg msg; fxDelay.set(\dhpf, msg[1]) });
        this.addCommand(\d_lpf, "f", { arg msg; fxDelay.set(\lpf, msg[1]) });
        this.addCommand(\d_wrate, "f", { arg msg; fxDelay.set(\w_rate, msg[1]) });
        this.addCommand(\d_stereo, "f", { arg msg; fxDelay.set(\stereo, msg[1]) });
        this.addCommand(\d_duck, "f", { arg msg; fxDelay.set(\duck_amt, msg[1]) });
        this.addCommand(\d_wdepth, "f", { arg msg; fxDelay.set(\w_depth, msg[1] / 100); });
        this.addCommand("d_mix", "f", { arg msg; fxDelay.set(\mix, msg[1]); fxDelay.run(msg[1] > 0); });
        this.addCommand(\sh_oct, "f", { arg msg; fxShimmer.set(\shimmer_oct1, msg[1]) });
        this.addCommand(\sh_lowpass, "f", { arg msg; fxShimmer.set(\lowpass1, msg[1]) });
        this.addCommand(\sh_hipass, "f", { arg msg; fxShimmer.set(\hipass1, msg[1]) });
        this.addCommand(\sh_pitchv, "f", { arg msg; fxShimmer.set(\pitchv1, msg[1]) });
        this.addCommand(\sh_fb, "f", { arg msg; fxShimmer.set(\fb1, msg[1]) });
        this.addCommand(\sh_fbdelay, "f", { arg msg; fxShimmer.set(\fbDelay1, msg[1]) });
        this.addCommand(\sh_mod, "i", { arg msg; fxShimmer.set(\mod_mix, msg[1]); });
        this.addCommand("sh_mix", "f", { arg msg; fxShimmer.set(\mix, msg[1]); fxShimmer.run(msg[1] > 0); });
        this.addCommand("tilt", "f", { arg msg; fxTilt.set(\tilt, msg[1]); fxTilt.run(msg[1] != 0); });
        this.addCommand("dimension_mix", "f", { arg msg; fxDimension.set(\mix, msg[1]); fxDimension.run(msg[1] > 0); });
        this.addCommand("m_width", "f", { arg msg; fxMain.set(\width, msg[1]) });
        this.addCommand("eq_low", "f", { arg msg; eqLow = msg[1]; fxEq.set(\low, msg[1]); this.updateEq });
        this.addCommand("eq_mid", "f", { arg msg; eqMid = msg[1]; fxEq.set(\mid, msg[1]); this.updateEq });
        this.addCommand("eq_high", "f", { arg msg; eqHigh = msg[1]; fxEq.set(\high, msg[1]); this.updateEq });
        this.addCommand("tape_mix", "f", { arg msg; if(fxTape.notNil, { fxTape.set(\mix, msg[1]); fxTape.run(msg[1] > 0) }) });
        this.addCommand("shaper_mix", "f", { arg msg; fxShaper.set(\mix, msg[1]); fxShaper.run(msg[1] > 0) });
        this.addCommand("wobble_mix", "f", { arg msg; fxWobble.set(\mix, msg[1]); fxWobble.run(msg[1] > 0) });
        this.addCommand(\wobble_amp, "f", { arg msg; fxWobble.set(\wobble_amp, msg[1]) });
        this.addCommand(\wobble_rpm, "f", { arg msg; fxWobble.set(\wobble_rpm, msg[1]) });
        this.addCommand(\flutter_amp, "f", { arg msg; fxWobble.set(\flutter_amp, msg[1]) });
        this.addCommand(\flutter_freq, "f", { arg msg; fxWobble.set(\flutter_freq, msg[1]) });
        this.addCommand(\flutter_var, "f", { arg msg; fxWobble.set(\flutter_var, msg[1]) });
        this.addCommand("haas", "i", { arg msg; fxHaas.run(msg[1] > 0) });
        this.addCommand("rspeed", "f", { arg msg; fxRotate.set(\rspeed, msg[1]); fxRotate.run(msg[1] > 0) });
        this.addCommand("bc_mix", "f", { arg msg; fxBitcrush.set(\mix, msg[1]); fxBitcrush.run(msg[1] > 0) });
        this.addCommand("bc_mod", "i", { arg msg; fxBitcrush.set(\mod_mix, msg[1]) });
        this.addCommand(\bc_rate, "f", { arg msg; fxBitcrush.set(\rate, msg[1]) });
        this.addCommand(\bc_bits, "f", { arg msg; fxBitcrush.set(\bits, msg[1]) });
        this.addCommand("reso_mix", "f", { arg msg; fxResonator.set(\mix, msg[1]); fxResonator.run(msg[1] > 0) });
        this.addCommand(\reso_decay, "f", { arg msg; fxResonator.set(\decay, msg[1]) });
        this.addCommand("reso_freqs", "fffff", { arg msg; fxResonator.set(\f1, msg[1], \f2, msg[2], \f3, msg[3], \f4, msg[4], \f5, msg[5]) });
        this.addCommand("wf_mix", "f", { arg msg; fxWavefold.set(\mix, msg[1]); fxWavefold.run(msg[1] > 0) });
        this.addCommand(\wf_drive, "f", { arg msg; fxWavefold.set(\drive, msg[1]) });
        this.addCommand(\wf_sym, "f", { arg msg; fxWavefold.set(\sym, msg[1]) });
        this.addCommand("gl_ratio", "f", { arg msg; glRatio = msg[1]; fxGlitch.set(\glitch_ratio, msg[1]); this.updateGlitch });
        this.addCommand("gl_mix", "f", { arg msg; glMix = msg[1]; fxGlitch.set(\mix, msg[1]); this.updateGlitch });
        this.addCommand(\gl_prob, "f", { arg msg; fxGlitch.set(\probability, msg[1]) });
        this.addCommand(\gl_min, "f", { arg msg; fxGlitch.set(\minLength, msg[1]) });
        this.addCommand(\gl_max, "f", { arg msg; fxGlitch.set(\maxLength, msg[1]) });
        this.addCommand(\gl_stutters, "i", { arg msg; fxGlitch.set(\maxStutters, msg[1]) });
        this.addCommand(\gl_rev, "f", { arg msg; fxGlitch.set(\reverse, msg[1]) });
        this.addCommand(\gl_pitch, "f", { arg msg; fxGlitch.set(\pitch, msg[1]) });
        this.addCommand("bounce", "fsf", { arg msg; this.bounce(msg[1], msg[2].asString, msg[3]) });
        this.addCommand("rec_start", "sfffff", { arg msg; this.recStart(msg[1].asString, msg[2], msg[3], msg[4], msg[5], msg[6]) });
        this.addCommand("rec_stop", "i", { arg msg; this.recStop(msg[1].asInteger) });

        oState = OSCFunc({ |msg| nornsAddr.sendMsg(*(["/grains/state"] ++ msg[3..])); }, '/grains_state', context.server.addr);
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
         fxHaas, fxRotate, pg].do({ arg x; if(x.notNil, { x.free }); });
        buffers.do({ arg b; if(b.notNil and: { b !== silent }, { b.free }) });
        [wobbleBuffer, glitchBuffer, bufSine].do({ arg b; if(b.notNil, { b.free }) });
        if(silent.notNil, { silent.free });
        [stateBus, busMain].do({ arg b; if(b.notNil, { b.free }) });
    }
}
