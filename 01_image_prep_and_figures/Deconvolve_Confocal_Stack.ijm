// Deconvolution workflow for point-scanning confocal stacks (60x / 100x oil objectives, 1 AU pinhole).
//
//   1. Pick a microscope file (.oir, .czi, .lif, .nd2, OME-TIFF ...) and the series to process, or a
//      folder: every microscope file in it is processed with the settings chosen for the first file
//      (files with another channel count, objective NA or a time-lapse are skipped and listed).
//   2. Read NA, refractive index, voxel size and each channel's excitation/emission from the file.
//   3. Check Nyquist sampling and warn when the stack is too coarse for deconvolution to help.
//   4. Build a Gaussian confocal PSF per channel and series (Zeiss "Confocal Laser Scanning
//      Microscopy" principles, eq. 2-3: FWHM_lat = 0.51 lex/NA, FWHM_ax = 0.88 lex/(n - sqrt(n^2 - NA^2)),
//      valid for pinholes >= 1 AU; sigma = FWHM / 2.355).
//   5. Trial: for every non-nuclear channel, deconvolve a crop around its brightest structure at
//      several iteration counts and show a montage plus contrast and noise relative to raw, then
//      pick the count (pre-selected: highest contrast-to-noise). Nuclear channels (DAPI/Hoechst) use a
//      fixed count without a trial.
//   6. Batch: deconvolve every selected series with plain Richardson-Lucy (core ImageJ, no plugins)
//      and save, inside the chosen output folder:
//        deconvolved/   calibrated 32-bit TIFFs named <name>_C<n>_deconvolved.tif (a channel set to
//                       'raw' or left undeconvolved by the trial is saved unchanged as <name>_C<n>_raw.tif)
//        qc/            a raw-vs-deconvolved image per channel; qc/trial/ holds the trial montages
//        figures/       (optional) per image: one panel per channel (max projection, colour, scale bar)
//                       and merges; one display range per channel for all images (figure_settings.csv)
//        deconvolution_manifest.csv   one line per channel (PSF parameters, iterations) for methods
//   'Figures only' remakes figures/ from an existing deconvolved/ folder (other colours or brightness).
//   Setting every channel to 'raw' makes figures from the raw data without deconvolving.
//
// Requires: only Fiji (Bio-Formats is bundled). Deconvolution runs on core ImageJ commands.
// The PSF is an approximation: fine for cells within a few um of the coverslip; deeper in aqueous
// samples the real PSF degrades (refractive-index mismatch) and a measured PSF is better.

// ---- settings ----
trialIterations   = newArray(10, 20, 40);   // counts compared in the trial
nuclearIterations = 10;                       // fixed count for DAPI / Hoechst channels
cropSize          = 128;                      // trial crop width/height (px)
presetNA          = 1.4;                      // used only if the file has no NA
presetRI          = 1.518;                    // used only if the file has no refractive index (oil)
interactive       = true;                     // false = accept the suggested choices without dialogs
// ------------------

// (No global 'var' variables: Fiji's script editor and menu commands can wrap a macro in a way that
// breaks them. Every function returns its result instead.)

requires("1.54");
modes = newArray("Deconvolve + figures", "Deconvolve only", "Figures only (from deconvolved TIFFs)");
mode = modes[0];
inputs = newArray("One file", "Every file in a folder");
input = inputs[0];
if (interactive) {
    Dialog.create("Deconvolution workflow");
    Dialog.addRadioButtonGroup("What to do", modes, 3, 1, mode);
    Dialog.addRadioButtonGroup("Deconvolve", inputs, 2, 1, input);
    Dialog.addMessage("'Every file in a folder': the trial runs once on the first file and its settings are used for all files.\n'Figures only' remakes figures from a 'deconvolved' folder without deconvolving again\n(e.g. to change colours or brightness).");
    Dialog.show();
    mode = Dialog.getRadioButton();
    input = Dialog.getRadioButton();
}
setOption("BlackBackground", true);

// ---- figures only: remake figures from an existing 'deconvolved' folder ----
if (mode == modes[2]) {
    dir = getDirectory("Choose the 'deconvolved' folder");
    figDir = dir + "figures" + File.separator;
    if (File.getName(dir) == "deconvolved") figDir = File.getParent(dir) + File.separator + "figures" + File.separator;
    list = getFileList(dir);
    files = newArray();
    for (i = 0; i < list.length; i++) if (isChannelFile(list[i])) files = Array.concat(files, list[i]);
    if (files.length == 0) exit("No <name>_C<n>_deconvolved.tif or <name>_C<n>_raw.tif files in\n" + dir);
    figCh = channelsIn(files);
    figLut = defaultColours(newArray(figCh.length));
    if (File.exists(figDir + "figure_settings.csv")) {       // reuse the colours of the previous run
        rows = split(File.openAsString(figDir + "figure_settings.csv"), "\n");
        for (r = 1; r < rows.length; r++) {
            f = split(rows[r], ",");
            i = indexOfValue(figCh, parseInt(substring(f[0], 1)));
            if (i >= 0) figLut[i] = f[1];
        }
    }
    figLo = newArray(figCh.length); figHi = newArray(figCh.length);
    figOpts = newArray(1, 1, 10, "PNG");
    setBatchMode(true);
    displayRanges(dir, files, figCh, figLo, figHi);
    if (interactive) figureDialog(figCh, figLut, figLo, figHi, figOpts, true);
    n = makeFigures(dir, files, figDir, figCh, figLut, figLo, figHi, figOpts);
    setBatchMode(false);
    done = "Made figures for " + n + " image(s) in:\n" + figDir + "\n \nDisplay ranges used: figure_settings.csv in that folder.";
    print("Done. " + done);
    if (interactive) showMessage("Figures finished", done);
    exit;
}

// ---- input: one file or every microscope file in a folder ----
if (input == inputs[1]) {
    inDir = getDirectory("Choose the folder with your microscope files");
    list = getFileList(inDir);
    files = newArray();
    for (i = 0; i < list.length; i++) if (isMicroscopeFile(list[i])) files = Array.concat(files, inDir + list[i]);
    if (files.length == 0) exit("No microscope files (.oir, .czi, .lif, .nd2, .tif ...) in\n" + inDir);
    Array.sort(files);                                       // trial always runs on the first file by name
} else {
    files = newArray(File.openDialog("Choose a confocal file (.oir, .czi, .lif, OME-TIFF ...)"));
}
outDir = getDirectory("Choose a folder for the deconvolved images");
srcDir = File.getParent(files[0]) + File.separator;
if (sameFolder(srcDir, outDir)) {
    msg = "The output folder is the folder that holds your raw data:\n" + outDir
        + "\n \nResults will be written next to the original files (nothing is overwritten).\nA separate output folder keeps raw and processed data apart.";
    print("Warning: " + msg);
    if (interactive) showMessageWithCancel("Output folder = raw-data folder", msg + "\n \nContinue anyway?");
}
setBatchMode(true);
// output layout: <outDir>/deconvolved/*.tif, <outDir>/qc/*_qc.png, <outDir>/qc/trial/*.png, manifest in <outDir>
decDir = outDir + "deconvolved" + File.separator;
qcDir = outDir + "qc" + File.separator;
trialDir = qcDir + "trial" + File.separator;
File.makeDirectory(decDir);
File.makeDirectory(qcDir);
File.makeDirectory(trialDir);
manifest = outDir + "deconvolution_manifest.csv";
manifestHead = "file,series,series_name,channel,channel_name,handling,ex_nm,ex_assumed,em_nm,NA,refractive_index,pixel_um,z_step_um,psf_fwhm_xy_um,psf_fwhm_z_um,algorithm,iterations,nyquist_xy,nyquist_z,output";
newRows = "";                                            // this run's manifest rows (written at the end)
usedBases = newArray();                                  // output names taken in this run
nSaved = 0; skipped = "";
sumFile = newArray(); sumSeries = newArray(); sumChannel = newArray(); sumRole = newArray(); sumIters = newArray(); sumOut = newArray();

// The first file sets everything (series, optics, channel handling, trial); every file is then processed the same way.
for (fi = 0; fi < files.length; fi++) {
    path = files[fi];
    if (files.length > 1) print("File " + (fi + 1) + "/" + files.length + ": " + File.getName(path));
    lines = split(readMetadata(path), "\n");
    if (lines.length == 0 || startsWith(lines[0], "E")) {
        reason = "is damaged or not a microscope file";
        if (lines.length > 0) { e = shortError(substring(lines[0], 2), path); reason = reason + " (" + e + ")"; }
        if (fi == 0) exit(File.getName(path) + " " + reason + ".\nThe first file sets up the run, so it must open.");
        msg = File.getName(path) + " " + reason + ": skipped";
        print(msg); skipped = skipped + msg + "\n";
        continue;
    }
    sName = newArray(); sX = newArray(); sZ = newArray(); sC = newArray(); sT = newArray(); sOk = newArray(); sPx = newArray(); sPz = newArray();
    sNA = newArray(); sRI = newArray(); sImm = newArray();
    chS = newArray(); chC = newArray(); chName = newArray(); chEx = newArray(); chEm = newArray();
    for (i = 0; i < lines.length; i++) {
        f = split(lines[i], "\t");
        if (f[0] == "S") {
            s = parseInt(f[1]);
            sName[s] = f[2]; sX[s] = parseInt(f[3]); sZ[s] = parseInt(f[4]); sC[s] = parseInt(f[5]);
            sPx[s] = parseFloat(f[6]); sPz[s] = parseFloat(f[7]); sNA[s] = parseFloat(f[8]); sRI[s] = parseFloat(f[9]);
            sT[s] = parseInt(f[10]); sOk[s] = parseInt(f[11]);
            sImm[s] = ""; if (f.length > 13) sImm[s] = f[13];
            if (sPz[s] <= 0) sPz[s] = sPx[s];
        } else if (f[0] == "C") {
            j = chS.length;
            chS[j] = parseInt(f[1]); chC[j] = parseInt(f[2]); chName[j] = f[3]; chEx[j] = parseFloat(f[4]); chEm[j] = parseFloat(f[5]);
        }
    }
    nSeries = sName.length;
    maxX = 0;
    for (s = 0; s < nSeries; s++) maxX = maxOf(maxX, sX[s]);
    use = newArray(nSeries);
    for (s = 0; s < nSeries; s++) use[s] = (sX[s] >= maxX / 2);   // pyramid / overview series default to off

    if (fi == 0) {
        // ---- 1. series selection ----
        labels = newArray(nSeries);
        for (s = 0; s < nSeries; s++) labels[s] = "" + (s + 1) + ": " + sName[s] + "  (Z " + sZ[s] + ", C " + sC[s] + ", " + d2s(sPx[s] * 1000, 0) + " nm px, " + d2s(sPz[s], 3) + " um z)";
        if (interactive) {
            Dialog.create("Deconvolution: choose series");
            msg = File.getName(path) + " contains " + nSeries + " series.";
            if (files.length > 1) msg = msg + "\nThe settings you choose for this first file apply to all " + files.length + " files in the folder\n(their full-size series are processed; files that do not match are skipped).";
            Dialog.addMessage(msg);
            for (s = 0; s < nSeries; s++) Dialog.addCheckbox(labels[s], use[s]);
            Dialog.show();
            for (s = 0; s < nSeries; s++) use[s] = Dialog.getCheckbox();
        }
        first = -1;
        for (s = 0; s < nSeries; s++) if (use[s] && first < 0) first = s;
        if (first < 0) exit("No series selected.");
        if (sPx[first] <= 0) exit(File.getName(path) + " series " + (first + 1) + " has no pixel size in its metadata; this workflow needs calibrated original files.");
        if (sOk[first] == 0) exit(File.getName(path) + " series " + (first + 1) + " could not be read (file damaged or incomplete); the first file sets up the run, so it must open.");
        if (sT[first] > 1) exit(File.getName(path) + " series " + (first + 1) + " is a time-lapse; time-lapse series are not supported.");
        na0 = sNA[first];                                  // the objective NA in the file, to check the other files against

        // ---- 2. optics and channel roles (from the first selected series) ----
        nc = sC[first];
        role = newArray(nc);
        iters = newArray(nc);
        exAssumed = newArray(nc);
        na = sNA[first]; ri = sRI[first];
        if (na <= 0) na = presetNA;
        if (ri <= 0) ri = immersionIndex(sImm[first], presetRI);
        for (c = 0; c < nc; c++) {
            k = chanRow(chS, chC, first, c);
            role[c] = "trial";
            if (isNuclear(chName[k], chEm[k])) role[c] = "nuclear";
            if (chEx[k] <= 0) { exAssumed[c] = 1; if (chEm[k] > 0) chEx[k] = chEm[k] - 30; else chEx[k] = 488; }
        }
        if (interactive) {
            Dialog.create("Deconvolution: optics and channels");
            Dialog.addMessage("Values read from the file. Change only what is wrong or missing.");
            Dialog.addNumber("Objective NA", na, 2, 6, "");
            Dialog.addNumber("Immersion refractive index", ri, 3, 6, "");
            roles = newArray("trial", "nuclear", "raw (no deconvolution)", "skip");
            for (c = 0; c < nc; c++) {
                k = chanRow(chS, chC, first, c);
                note = "";
                if (exAssumed[c]) note = "  (excitation not in file - assumed)";
                Dialog.addMessage("C" + (c + 1) + " " + chName[k] + note);
                Dialog.addNumber("C" + (c + 1) + " excitation", chEx[k], 0, 6, "nm");
                Dialog.addChoice("C" + (c + 1) + " handling", roles, role[c]);
            }
            Dialog.show();
            na = Dialog.getNumber();
            ri = Dialog.getNumber();
            for (c = 0; c < nc; c++) {
                k = chanRow(chS, chC, first, c);
                chEx[k] = Dialog.getNumber();
                role[c] = Dialog.getChoice();
            }
        }
        for (c = 0; c < nc; c++) if (role[c] == "nuclear") iters[c] = nuclearIterations;
        exT = newArray(nc);                                 // excitation per channel, used for every file
        for (c = 0; c < nc; c++) { k = chanRow(chS, chC, first, c); exT[c] = chEx[k]; }

        // figure options are asked now so the long run needs no attention; display ranges are set at the end
        doFigures = (mode == modes[0]);
        if (doFigures) {
            figCh = newArray(); figNuc = newArray();
            for (c = 0; c < nc; c++) {
                if (role[c] == "skip") continue;
                nuc = 0; if (role[c] == "nuclear") nuc = 1;
                figCh = Array.concat(figCh, c + 1); figNuc = Array.concat(figNuc, nuc);
            }
            figLut = defaultColours(figNuc);
            figLo = newArray(figCh.length); figHi = newArray(figCh.length);
            figOpts = newArray(1, 1, 10, "PNG");
            if (interactive && figCh.length > 0) figureDialog(figCh, figLut, figLo, figHi, figOpts, false);
        }

        // ---- 3. Nyquist check for every selected series ----
        warnings = "";
        for (s = 0; s < nSeries; s++) {
            if (!use[s]) continue;
            for (c = 0; c < minOf(nc, sC[s]); c++) {
                if (role[c] == "skip" || startsWith(role[c], "raw")) continue;
                lex = exT[c];
                fl = fwhmLat(lex, na); fa = fwhmAx(lex, na, ri);
                if (sPx[s] > fl / 2) warnings = warnings + "Series " + (s + 1) + " C" + (c + 1) + ": pixel " + d2s(sPx[s] * 1000, 0) + " nm > " + d2s(fl / 2 * 1000, 0) + " nm (Nyquist)\n";
                if (sZ[s] > 1 && sPz[s] > fa / 2) warnings = warnings + "Series " + (s + 1) + " C" + (c + 1) + ": z-step " + d2s(sPz[s], 3) + " um > " + d2s(fa / 2, 3) + " um (Nyquist)\n";
                if (sZ[s] == 1) warnings = warnings + "Series " + (s + 1) + ": single plane - 2D deconvolution gains little\n";
            }
        }
        if (warnings != "") {
            print("Sampling warnings (deconvolution will help less where the data are undersampled):\n" + warnings);
            if (interactive) showMessageWithCancel("Sampling check", "Some data are coarser than Nyquist; deconvolution will help less there:\n \n" + warnings + " \nContinue?");
        }

        // ---- 4. trial on the first selected series ----
        err = openSeries(path, first);
        if (err != "") exit(File.getName(path) + " series " + (first + 1) + " could not be opened:\n" + err);
        stack = getTitle();
        for (c = 0; c < nc; c++) {
            if (role[c] != "trial") continue;
            k = chanRow(chS, chC, first, c);
            selectWindow(stack);
            run("Duplicate...", "title=trialRaw duplicate channels=" + (c + 1));
            cropBrightest("trialRaw", cropSize);
            nt = trialIterations.length;
            cnr = newArray(nt + 1); contrast = newArray(nt + 1); noise = newArray(nt + 1);
            projectTo("trialRaw", "mip0");
            bgMask("mip0");
            peaks = findPeaks("mip0");
            measure("mip0", 0, cnr, contrast, noise, peaks);
            for (t = 0; t < nt; t++) {
                deconvolve("trialRaw", exT[c], na, ri, sPx[first], sPz[first], trialIterations[t], "trialOut");
                projectTo("trialOut", "mip" + (t + 1));
                close("trialOut");
                measure("mip" + (t + 1), t + 1, cnr, contrast, noise, peaks);
            }
            best = 1;
            for (t = 1; t <= nt; t++) if (cnr[t] > cnr[best]) best = t;
            keepRaw = "Keep raw (no deconvolution)";
            choices = newArray(nt + 1);
            choices[0] = keepRaw;
            for (t = 0; t < nt; t++) choices[t + 1] = "" + trialIterations[t] + " iterations: contrast x" + d2s(contrast[t + 1] / contrast[0], 2) + ", noise x" + d2s(noise[t + 1] / noise[0], 2);
            trialPng = trialDir + "trial_C" + (c + 1) + ".png";
            montage(nt, trialIterations, trialPng);
            pick = choices[best];
            if (cnr[best] <= cnr[0]) pick = keepRaw;          // no count beats raw: suggest leaving the channel alone
            print("Trial C" + (c + 1) + " " + chName[k] + ":");
            for (t = 0; t < nt; t++) print("   " + choices[t + 1] + "   (contrast-to-noise " + d2s(cnr[t + 1] / cnr[0], 2) + "x raw)");
            if (interactive) {
                Dialog.createNonBlocking("Deconvolution: choose iterations for C" + (c + 1) + " " + chName[k]);
                Dialog.addMessage("Panels, left to right: raw, then each iteration count (each autoscaled).\nPick the count where structures are sharper but the background is not yet grainy.\nThe numbers compare each result with raw. Pre-selected: the highest contrast-to-noise,\nor 'Keep raw' when no count improves on raw.");
                Dialog.addImage(trialPng);
                Dialog.addChoice("Iterations", choices, pick);
                Dialog.show();
                pick = Dialog.getChoice();
            }
            iters[c] = 0;
            for (t = 0; t < nt; t++) if (choices[t + 1] == pick) iters[c] = trialIterations[t];
            if (iters[c] == 0) print("C" + (c + 1) + " " + chName[k] + ": kept raw (no deconvolution)");
            else print("C" + (c + 1) + " " + chName[k] + ": " + iters[c] + " iterations");
            close("trialRaw"); close("mip*"); close("bg");
        }
        close("*");
    }

    // ---- 5. batch: every selected series of this file ----
    stem = File.getNameWithoutExtension(path);
    if (endsWith(toLowerCase(stem), ".ome")) stem = substring(stem, 0, lengthOf(stem) - 4);
    for (s = 0; s < nSeries; s++) {
        if (!use[s]) continue;
        why = "";
        if (sC[s] != nc) why = "has " + sC[s] + " channel(s), the first file has " + nc;
        if (sT[s] > 1) why = "reads as a time-lapse (not supported)";
    if (sOk[s] == 0) why = "is damaged (image data could not be read)";
        if (sPx[s] <= 0) why = "has no pixel size in its metadata";
        if (na0 > 0 && sNA[s] > 0 && abs(sNA[s] - na0) > 0.02) why = "was taken at NA " + sNA[s] + " (first file: NA " + na0 + ")";
        if (why != "") {
            msg = File.getName(path) + " series " + (s + 1) + " " + why + ": skipped";
            print(msg); skipped = skipped + msg + "\n";
            continue;
        }
        base = sanitize(stem);
        if (nSeries > 1) { sn = sanitize(sName[s]); base = base + "_" + sn; }
        // two inputs can sanitize to the same name (cell1.oir and cell1.tif, "cell 1" and "cell_1"): number them
        b0 = base; k2 = 2; while (indexOfValue(usedBases, base) >= 0) { base = b0 + "_" + k2; k2++; }
        usedBases = Array.concat(usedBases, base);
        err = openSeries(path, s);
        if (err != "") {
            e = shortError(err, path);
            msg = File.getName(path) + " series " + (s + 1) + " is damaged (" + e + "): skipped";
            print(msg); skipped = skipped + msg + "\n";
            close("*");
            continue;
        }
        stack = getTitle();
        for (c = 0; c < nc; c++) {
            if (role[c] == "skip") continue;
            k = chanRow(chS, chC, s, c);
            lex = exT[c];
            selectWindow(stack);
            run("Duplicate...", "title=raw duplicate channels=" + (c + 1));
            if (iters[c] > 0) {
                deconvolve("raw", lex, na, ri, sPx[s], sPz[s], iters[c], "out");
                setVoxelSize(sPx[s], sPx[s], sPz[s], "micron");
                outName = base + "_C" + (c + 1) + "_deconvolved.tif";
                saveAs("Tiff", decDir + outName);
                rename("out");
                qcImage("raw", "out", qcDir + base + "_C" + (c + 1) + "_qc.png");
                algo = "Richardson-Lucy (Gaussian PSF; core ImageJ)";
            } else {
                // 'raw' channel or trial chose 'Keep raw': save the untouched channel (original bit depth), clearly named
                selectWindow("raw");
                run("Duplicate...", "title=out duplicate");
                setVoxelSize(sPx[s], sPx[s], sPz[s], "micron");
                outName = base + "_C" + (c + 1) + "_raw.tif";
                saveAs("Tiff", decDir + outName);
                rename("out");
                algo = "none (kept raw)";
            }
            fl = fwhmLat(lex, na); fa = fwhmAx(lex, na, ri);
            nyXY = "ok"; if (sPx[s] > fl / 2) nyXY = "undersampled";
            nyZ = "ok"; if (sPz[s] > fa / 2) nyZ = "undersampled";
            if (sZ[s] == 1) nyZ = "2D";
            exNote = "no"; if (exAssumed[c]) exNote = "yes";
            q1 = csv(File.getName(path)); q2 = csv(sName[s]); q3 = csv(chName[k]); q4 = csv(outName);
            newRows = newRows + q1 + "," + (s + 1) + "," + q2 + "," + (c + 1) + "," + q3 + "," + role[c] + ","
                + lex + "," + exNote + "," + chEm[k] + "," + na + "," + ri + "," + d2s(sPx[s], 4) + "," + d2s(sPz[s], 4) + ","
                + d2s(fl, 4) + "," + d2s(fa, 4) + "," + algo + "," + iters[c] + "," + nyXY + "," + nyZ + "," + q4 + "\n";
            close("raw"); close("out");
            print("Saved " + outName);
            sumFile[nSaved] = File.getName(path); sumSeries[nSaved] = sName[s]; sumChannel[nSaved] = "C" + (c + 1) + " " + chName[k];
            sumRole[nSaved] = role[c]; sumIters[nSaved] = iters[c]; sumOut[nSaved] = outName;
            nSaved++;
        }
        close("*");
    }
}
figDir = outDir + "figures" + File.separator;
if (doFigures && nSaved > 0) {
    print("Making figures ...");
    displayRanges(decDir, sumOut, figCh, figLo, figHi);
    makeFigures(decDir, sumOut, figDir, figCh, figLut, figLo, figHi, figOpts);
}
setBatchMode(false);
Table.create("Deconvolution summary");
for (r = 0; r < nSaved; r++) {
    Table.set("File", r, sumFile[r]);
    Table.set("Series", r, sumSeries[r]);
    Table.set("Channel", r, sumChannel[r]);
    Table.set("Handling", r, sumRole[r]);
    Table.set("Iterations", r, sumIters[r]);
    Table.set("Output", r, sumOut[r]);
}
Table.update;
if (isOpen("Results")) { selectWindow("Results"); run("Close"); }   // leftover from the trial's peak finding
// manifest: rows of earlier runs kept, except those for an output this run wrote again (no duplicates)
kept = "";
if (File.exists(manifest)) {
    old = split(File.openAsString(manifest), "\n");
    for (r = 1; r < old.length; r++) {
        f = split(old[r], ","); o = f[f.length - 1];
        if (indexOf(newRows, "," + o + "\n") < 0) kept = kept + old[r] + "\n";
    }
}
File.saveString(manifestHead + "\n" + kept + newRows, manifest);
done = "Saved " + nSaved + " channel stack(s) from " + files.length + " file(s).\n \nDeconvolved stacks:  " + decDir + "\nQC images:  " + qcDir + "\nManifest (for methods):  " + manifest;
if (doFigures && nSaved > 0) done = done + "\nFigures:  " + figDir;
if (skipped != "") done = done + "\n \nNot processed:\n" + skipped + "A file listed here that should match the others is most likely damaged.\n";
print("Done. " + done);
if (interactive) showMessage("Deconvolution finished", done + "\n \nThe 'Deconvolution summary' table lists every channel.");

// ================= functions =================

function chanRow(chS, chC, s, c) {
    for (j = 0; j < chS.length; j++) if (chS[j] == s && chC[j] == c) return j;
    exit("Channel " + (c + 1) + " not found in series " + (s + 1));
}

function isNuclear(name, em) {
    n = toLowerCase(name);
    if (indexOf(n, "dapi") >= 0 || indexOf(n, "hoechst") >= 0) return true;
    if (em > 0 && em < 480) return true;
    return false;
}

function immersionIndex(imm, fallback) {
    i = toLowerCase(imm);
    if (i == "oil") return 1.518;
    if (i == "water" || i == "waterdipping") return 1.333;
    if (i == "glycerol") return 1.47;
    if (indexOf(i, "silicon") >= 0) return 1.40;
    return fallback;
}

// Zeiss confocal principles, eq. 3 and 2 (pinhole >= 1 AU), in um.
function fwhmLat(lexNm, na) { return 0.51 * lexNm / 1000 / na; }
function fwhmAx(lexNm, na, n) { return 0.88 * lexNm / 1000 / (n - sqrt(n * n - na * na)); }

// Plain Richardson-Lucy with the Gaussian confocal PSF, using only core ImageJ:
//   estimate <- estimate * blur(observed / blur(estimate))
// A Gaussian is symmetric, so the adjoint (flipped-PSF) blur is the same blur. Gaussian Blur 3D takes
// sigma in pixels. Leaves the 32-bit result as `outTitle` (active). Validated against DeconvolutionLab2
// RL on synthetic 100x stacks: bead FWHM within 6% laterally and 3% axially at 10-40 iterations.
function deconvolve(img, lexNm, na, n, px, pz, iterations, outTitle) {
    // (ImageJ macros cannot use a user-function result inside a larger expression: assign first)
    sxy = fwhmLat(lexNm, na);
    sxy = sxy / 2.3548 / px;
    sz = fwhmAx(lexNm, na, n);
    sz = sz / 2.3548 / pz;
    selectWindow(img);
    if (nSlices == 1) sz = 0;
    blur = "x=" + sxy + " y=" + sxy + " z=" + sz;
    run("Duplicate...", "title=rl_obs duplicate");
    run("32-bit");
    run("Min...", "value=0.000001 stack");          // RL needs strictly positive data
    run("Duplicate...", "title=" + outTitle + " duplicate");
    for (it = 0; it < iterations; it++) {
        selectWindow(outTitle);
        run("Duplicate...", "title=rl_blur duplicate");
        run("Gaussian Blur 3D...", blur);
        imageCalculator("Divide create 32-bit stack", "rl_obs", "rl_blur");
        rename("rl_ratio");
        close("rl_blur");
        selectWindow("rl_ratio");
        run("Gaussian Blur 3D...", blur);
        imageCalculator("Multiply stack", outTitle, "rl_ratio");
        close("rl_ratio");
        showProgress(it + 1, iterations);
    }
    close("rl_obs");
    selectWindow(outTitle);
}

// Crops the stack `title` in place to a size x size region centred on its brightest structure.
function cropBrightest(title, size) {
    selectWindow(title);
    getDimensions(w, h, c, z, t);
    if (w <= size && h <= size) return;
    projectTo(title, "crop_mip");
    f = maxOf(1, floor(maxOf(w, h) / 128));             // search on a binned copy: fast on large fields
    if (f > 1) run("Bin...", "x=" + f + " y=" + f + " bin=Average");
    run("Gaussian Blur...", "sigma=2");
    best = -1e30; bx = 0; by = 0;
    for (y = 0; y < getHeight(); y++) for (x = 0; x < getWidth(); x++) {
        v = getPixel(x, y);
        if (v > best) { best = v; bx = x * f + f / 2; by = y * f + f / 2; }
    }
    close();
    selectWindow(title);
    x0 = minOf(maxOf(0, bx - size / 2), w - minOf(size, w));
    y0 = minOf(maxOf(0, by - size / 2), h - minOf(size, h));
    makeRectangle(x0, y0, minOf(size, w), minOf(size, h));
    run("Crop");
    run("Select None");
}

// Background pixels = darkest half of the raw MIP; stored as a selection mask image "bg".
function bgMask(rawMip) {
    selectWindow(rawMip);
    run("Duplicate...", "title=bg");
    v = getValue("Median");
    setThreshold(-1e30, v);
    run("Convert to Mask");
}

// Peaks: local maxima of the raw MIP standing out by > 5 background SDs (at most 200, brightest first).
// Every trial result is scored at these same positions, so sharpening cannot move the goal posts.
function findPeaks(rawMip) {
    selectWindow("bg"); run("Create Selection");
    selectWindow(rawMip); run("Restore Selection");
    getStatistics(a, bgMean, mn, mx, bgSd);
    run("Select None");
    run("Find Maxima...", "prominence=" + maxOf(5 * bgSd, 1e-6) + " strict exclude output=List");
    n = minOf(nResults, 200);
    peaks = newArray(2 * n);                        // x0..xn-1, y0..yn-1
    for (j = 0; j < n; j++) { peaks[j] = getResult("X", j); peaks[n + j] = getResult("Y", j); }
    run("Clear Results");
    return peaks;
}

// Contrast = mean peak height above the background mean (max of the 3x3 pixels around each raw peak);
// noise = background SD (at least 1 grey level); CNR = contrast / noise. Without peaks, falls back to the image maximum.
function measure(mip, i, cnr, contrast, noise, peaks) {
    selectWindow("bg"); run("Create Selection");
    selectWindow(mip); run("Restore Selection");
    getStatistics(a, bgMean, mn, mx, bgSd);
    run("Select None");
    getStatistics(a, m, mn, imageMax);
    top = imageMax;
    np = peaks.length / 2;
    if (np > 0) {
        sum = 0;
        for (j = 0; j < np; j++) {
            best = -1e30;
            for (dy = -1; dy <= 1; dy++) for (dx = -1; dx <= 1; dx++) best = maxOf(best, getPixel(peaks[j] + dx, peaks[np + j] + dy));
            sum += best;
        }
        top = sum / np;
    }
    contrast[i] = top - bgMean;
    noise[i] = maxOf(bgSd, 1);   // floor of one grey level: a zero-clipped background (SD 0) would make every ratio meaningless
    cnr[i] = contrast[i] / noise[i];
}

// Raw | each trial result, labelled; saved as PNG (shown inside the trial dialog). Each panel is autoscaled the same way
// (0.35% saturated) so shape and background grain are visible; the dialog's contrast/noise numbers
// carry the quantitative comparison. Small crops are shown at 2x.
function montage(nt, its, file) {
    zoom = 1;
    selectWindow("mip0"); if (getWidth() < 256) zoom = 2;
    for (t = 0; t <= nt; t++) {
        selectWindow("mip" + t);
        run("Duplicate...", "title=panel" + t);
        if (zoom > 1) run("Size...", "width=" + (getWidth() * zoom) + " height=" + (getHeight() * zoom) + " interpolation=None");
        run("Enhance Contrast", "saturated=0.35"); run("8-bit"); run("RGB Color");
        setColor(255, 255, 0); setFont("SansSerif", 12, "bold");
        if (t == 0) txt = "raw"; else txt = "" + its[t - 1] + " it";
        drawString(txt, 4, 16);
    }
    selectWindow("panel0"); rename("acc");
    for (t = 1; t <= nt; t++) {
        run("Combine...", "stack1=acc stack2=panel" + t);
        rename("acc");
    }
    saveAs("PNG", file);
    close();
}

// Raw MIP | deconvolved MIP of one channel, each autoscaled, saved as PNG.
function qcImage(raw, dec, file) {
    projectTo(raw, "qa"); resetMinAndMax(); run("8-bit");
    projectTo(dec, "qb"); resetMinAndMax(); run("8-bit");
    run("Combine...", "stack1=qa stack2=qb");
    saveAs("PNG", file);
    close();
}

function isChannelFile(name) { return matches(name, ".*_C[0-9]+_(deconvolved|raw)\\.tif"); }
function baseOf(name) { return replace(name, "^(.*)_C[0-9]+_(deconvolved|raw)\\.tif$", "$1"); }
function channelOf(name) { return parseInt(replace(name, "^.*_C([0-9]+)_(deconvolved|raw)\\.tif$", "$1")); }

function indexOfValue(a, v) {
    for (i = 0; i < a.length; i++) if (a[i] == v) return i;
    return -1;
}

function channelsIn(files) {
    ch = newArray();
    for (i = 0; i < files.length; i++) {
        c = channelOf(files[i]);
        if (indexOfValue(ch, c) < 0) ch = Array.concat(ch, c);
    }
    Array.sort(ch);
    return ch;
}

// Nuclear channels blue; the others green, magenta, cyan, yellow, red in channel order.
function defaultColours(nuclear) {
    order = newArray("Green", "Magenta", "Cyan", "Yellow", "Red");
    luts = newArray(nuclear.length); j = 0;
    for (i = 0; i < nuclear.length; i++) {
        if (nuclear[i]) luts[i] = "Blue";
        else { luts[i] = order[j % order.length]; j++; }
    }
    return luts;
}

// Edits luts, lo, hi and opts (merge all, pairwise merges, scale bar um, format) in place.
function figureDialog(chNums, luts, lo, hi, opts, showRanges) {
    colours = newArray("Green", "Magenta", "Cyan", "Yellow", "Red", "Blue", "Grays");
    Dialog.create("Figures");
    msg = "Per image: one panel per channel (max projection) plus merges.\nEach channel uses ONE display range for all images, so brightness can be compared between images.";
    if (!showRanges) msg = msg + "\nDisplay ranges are set automatically after deconvolution; adjust them later with 'Figures only'.";
    Dialog.addMessage(msg);
    for (i = 0; i < chNums.length; i++) {
        Dialog.addChoice("C" + chNums[i] + " colour", colours, luts[i]);
        if (showRanges) {
            Dialog.addToSameRow(); Dialog.addNumber("min", lo[i], 2, 9, "");
            Dialog.addToSameRow(); Dialog.addNumber("max", hi[i], 2, 9, "");
        }
    }
    Dialog.addCheckbox("Merge of all channels", opts[0]);
    if (chNums.length > 2) Dialog.addCheckbox("Pairwise merges", opts[1]);
    Dialog.addNumber("Scale bar", opts[2], 0, 4, "um (0 = none)");
    Dialog.addChoice("Format", newArray("PNG", "TIFF", "JPEG"), opts[3]);
    Dialog.show();
    for (i = 0; i < chNums.length; i++) {
        luts[i] = Dialog.getChoice();
        if (showRanges) { lo[i] = Dialog.getNumber(); hi[i] = Dialog.getNumber(); }
    }
    opts[0] = Dialog.getCheckbox();
    if (chNums.length > 2) opts[1] = Dialog.getCheckbox();
    opts[2] = Dialog.getNumber();
    opts[3] = Dialog.getChoice();
}

// Opens a stack and leaves its 32-bit max projection as `title` (calibration kept).
function mipOf(path, title) {
    open(path);
    src = getTitle();
    if (nSlices > 1) {
        run("Z Project...", "projection=[Max Intensity]");
        mip = getTitle();
        close(src);
        selectWindow(mip);
    }
    run("32-bit");
    rename(title);
}

// Per channel: lowest 'low' and highest 'high' of the 0.35%-saturated range over all images.
function displayRanges(dir, files, chNums, lo, hi) {
    for (i = 0; i < chNums.length; i++) { lo[i] = 1e30; hi[i] = -1e30; }
    for (f = 0; f < files.length; f++) {
        i = indexOfValue(chNums, channelOf(files[f]));
        if (i < 0) continue;
        mipOf(dir + files[f], "range");
        run("Enhance Contrast", "saturated=0.35");
        getMinAndMax(a, b);
        lo[i] = minOf(lo[i], a); hi[i] = maxOf(hi[i], b);
        close("range");
    }
}

// Returns the number of images (file bases) made.
function makeFigures(dir, files, figDir, chNums, luts, lo, hi, opts) {
    File.makeDirectory(figDir);
    ext = ".png"; if (opts[3] == "TIFF") ext = ".tif"; if (opts[3] == "JPEG") { ext = ".jpg"; run("Input/Output...", "jpeg=95"); }
    settings = "channel,colour,display_min,display_max,projection\n";
    for (i = 0; i < chNums.length; i++) settings = settings + "C" + chNums[i] + "," + luts[i] + "," + lo[i] + "," + hi[i] + ",max intensity\n";
    File.saveString(settings, figDir + "figure_settings.csv");
    bases = newArray();
    for (f = 0; f < files.length; f++) { b = baseOf(files[f]); if (indexOfValue(bases, b) < 0) bases = Array.concat(bases, b); }
    for (b = 0; b < bases.length; b++) {
        present = newArray();
        for (i = 0; i < chNums.length; i++) {
            name = bases[b] + "_C" + chNums[i] + "_deconvolved.tif";
            if (indexOfValue(files, name) < 0) name = bases[b] + "_C" + chNums[i] + "_raw.tif";
            if (indexOfValue(files, name) < 0) continue;
            mipOf(dir + name, "f" + i);
            run("Duplicate...", "title=panel");
            setMinAndMax(lo[i], hi[i]);
            run(luts[i]);
            run("RGB Color");
            scaleBar(opts[2]);
            saveAs(opts[3], figDir + bases[b] + "_C" + chNums[i] + ext);
            close();
            present = Array.concat(present, i);
        }
        if (opts[0] && present.length > 1) mergeFigure(present, chNums, luts, lo, hi, opts[2], opts[3], figDir + bases[b], ext);
        if (opts[1] && present.length > 2)
            for (p = 0; p < present.length; p++) for (q = p + 1; q < present.length; q++)
                mergeFigure(newArray(present[p], present[q]), chNums, luts, lo, hi, opts[2], opts[3], figDir + bases[b], ext);
        close("*");
        print("Figures: " + bases[b]);
    }
    return bases.length;
}

// Merges the open MIPs f<i> for the indices in idx; saved as <stem>_merge_C2-C3....
function mergeFigure(idx, chNums, luts, lo, hi, barUm, fmt, stem, ext) {
    arg = ""; tag = "";
    for (j = 0; j < idx.length; j++) {
        arg = arg + "c" + (j + 1) + "=f" + idx[j] + " ";
        tag = tag + "-C" + chNums[idx[j]];
    }
    run("Merge Channels...", arg + "create keep");
    comp = getTitle();
    for (j = 0; j < idx.length; j++) {
        Stack.setChannel(j + 1);
        run(luts[idx[j]]);
        setMinAndMax(lo[idx[j]], hi[idx[j]]);
    }
    Stack.setDisplayMode("composite");
    run("RGB Color");
    scaleBar(barUm);
    saveAs(fmt, stem + "_merge_" + substring(tag, 1) + ext);
    close();
    close(comp);
}

// Burns a white scale bar (lower right) into the active RGB image, sized to the image width.
function scaleBar(um) {
    if (um <= 0) return;
    w = getWidth();
    getPixelSize(unit, pw, ph);
    if (um > w * pw / 2) {                       // bar wider than half the field: use the largest 1-2-5 length that fits a quarter
        nice = newArray(50, 20, 10, 5, 2, 1, 0.5, 0.2, 0.1);
        k = 0; while (k < nice.length - 1 && nice[k] > w * pw / 4) k++;
        um = nice[k];
    }
    run("Scale Bar...", "width=" + um + " height=" + maxOf(3, round(w / 150)) + " thickness=" + maxOf(3, round(w / 150))
        + " font=" + maxOf(12, round(w / 40)) + " color=White background=None location=[Lower Right] horizontal bold");
}

function csv(text) {
    return "\"" + replace(text, "\"", "'") + "\"";
}


// ======== shared functions: copied from lib/common.ijm by tools/build.py; edit them there, not here ========

// Reads series and channel metadata through Bio-Formats (OME model) inside try/catch, or a single 'E<tab>error'
// line for an unreadable file. One tab-separated line per series and per channel:
//   S  series  name  sizeX  sizeZ  sizeC  pixel_um  zstep_um  NA  refractive_index  sizeT  readable(1/0)  rgb_channels  immersion
//   C  series  channel  name (display colour and excitation, e.g. "CH2 (green 488 nm)")  excitation_nm  emission_nm
// Unknown numbers are -1.
function readMetadata(path) {
    p = jsText(path);
    js = "importClass(Packages.loci.formats.ImageReader); importClass(Packages.loci.formats.MetadataTools);"
       + "var U = Packages.ome.units.UNITS;"
       + "function len(q, u) { return q == null ? -1 : q.value(u).doubleValue(); }"
       + "function tryget(f) { try { return f(); } catch (e) { return null; } }"
       + "var r = new ImageReader(); var m = MetadataTools.createOMEXMLMetadata(); r.setMetadataStore(m); var out = [];"
       + "try { r.setId('" + p + "');"
       + "for (var s = 0; s < r.getSeriesCount(); s++) { r.setSeries(s);"
       + "  var ok = 1; try { r.openBytes(r.getImageCount() - 1); } catch (e) { ok = 0; }"
       + "  var nm = tryget(function () { return m.getImageName(s); }); if (nm == null) nm = 'Series' + (s + 1);"
       + "  var id = tryget(function () { return m.getObjectiveSettingsID(s); }); var na = -1, imm = '';"
       + "  for (var i = 0; i < m.getInstrumentCount(); i++) for (var o = 0; o < m.getObjectiveCount(i); o++) {"
       + "    var v = tryget(function () { return m.getObjectiveLensNA(i, o); });"
       + "    var match = id != null && String(m.getObjectiveID(i, o)) == String(id);"
       + "    if (v != null && (na < 0 || match)) { na = v; var im = tryget(function () { return m.getObjectiveImmersion(i, o); }); imm = im == null ? '' : String(im); } }"
       + "  var ri = tryget(function () { return m.getObjectiveSettingsRefractiveIndex(s); }); if (ri == null) ri = -1;"
       + "  out.push(['S', s, String(nm).replace(/[\\t\\n]/g, ' '), r.getSizeX(), r.getSizeZ(), r.getSizeC(),"
       + "    len(tryget(function () { return m.getPixelsPhysicalSizeX(s); }), U.MICROMETER),"
       + "    len(tryget(function () { return m.getPixelsPhysicalSizeZ(s); }), U.MICROMETER), na, ri, r.getSizeT(), ok, r.getRGBChannelCount(), imm].join('\\t'));"
       + "  for (var c = 0; c < r.getSizeC(); c++) {"
       + "    var cn = tryget(function () { return m.getChannelName(s, c); }); cn = cn == null ? 'C' + (c + 1) : String(cn).replace(/[\\t\\n,]/g, ' ');"
       + "    var col = tryget(function () { return m.getChannelColor(s, c); }), cname = '';"
       + "    if (col != null) { var R = col.getRed() > 100, G = col.getGreen() > 100, B = col.getBlue() > 100;"
       + "      cname = R && G && B ? 'grey' : R && G ? 'yellow' : R && B ? 'magenta' : G && B ? 'cyan' : R ? 'red' : G ? 'green' : B ? 'blue' : ''; }"
       + "    var ex = len(tryget(function () { return m.getChannelExcitationWavelength(s, c); }), U.NANOMETER);"
       + "    var em = len(tryget(function () { return m.getChannelEmissionWavelength(s, c); }), U.NANOMETER);"
       + "    var tag = []; if (cname != '') tag.push(cname); if (ex > 0) tag.push(Math.round(ex) + ' nm');"
       + "    if (tag.length > 0) cn = cn + ' (' + tag.join(' ') + ')';"
       + "    out.push(['C', s, c, cn, ex, em].join('\\t')); } }"
       + "} catch (e) { out = ['E\\t' + String(e).replace(/[\\t\\n]/g, ' ')]; }"
       + "try { r.close(); } catch (e) {} out.join('\\n');";
    return eval("js", js);
}

// text as the inside of a JavaScript '...' string: every backslash and quote escaped one by one (macro replace()
// treats a one-character pattern literally, so a regular-expression escape doubles the backslash).
function jsText(s) {
    out = "";
    for (i = 0; i < lengthOf(s); i++) { c = substring(s, i, i + 1); if (c == "\\" || c == "'") out = out + "\\"; out = out + c; }
    return out;
}

// Files Bio-Formats opens as microscope data (subfolders and hidden files skipped).
function isMicroscopeFile(name) {
    n = toLowerCase(name);
    if (endsWith(n, "/") || startsWith(n, ".")) return false;
    ext = newArray(".oir", ".oib", ".oif", ".czi", ".lsm", ".lif", ".lof", ".nd2", ".ims", ".vsi", ".zvi", ".dv", ".ics", ".tif", ".tiff");
    for (i = 0; i < ext.length; i++) if (endsWith(n, ext[i])) return true;
    return false;
}

// The readable part of a Java error: no exception class name, no file path.
function shortError(e, path) {
    e = replace(e, "^.*Exception: ", "");
    if (endsWith(e, File.getName(path)) && lastIndexOf(e, ": ") > 0) e = substring(e, 0, lastIndexOf(e, ": "));
    return e;
}

// Opens series s (0-based) as a hyperstack through Bio-Formats' API inside try/catch; returns "" or the error.
function openSeries(path, s) {
    p = jsText(path);
    js = "var I = Packages.loci.plugins['in'].ImporterOptions; var o = new I(); o.setId('" + p + "');"
       + "o.setColorMode(I.COLOR_MODE_DEFAULT); o.setStackOrder(I.ORDER_XYCZT); o.setQuiet(true); o.setOpenAllSeries(false);"
       + "o.setSeriesOn(0, false); o.setSeriesOn(" + s + ", true);"
       + "var err = ''; try { Packages.loci.plugins.BF.openImagePlus(o)[0].show(); } catch (e) { err = String(e); } err;";
    return eval("js", js);
}

function sameFolder(a, b) {
    a = replace(a, "\\\\", "/"); b = replace(b, "\\\\", "/");
    if (!endsWith(a, "/")) a = a + "/";
    if (!endsWith(b, "/")) b = b + "/";
    if (startsWith(getInfo("os.name"), "Windows")) { a = toLowerCase(a); b = toLowerCase(b); }
    if (a == b) return true;
    return false;
}

function sanitize(name) {
    return replace(name, "[^a-zA-Z0-9._-]", "_");
}

// Max projection of title (a copy when it is a single plane) named newTitle.
function projectTo(title, newTitle) {
    selectWindow(title);
    if (nSlices > 1) run("Z Project...", "projection=[Max Intensity]");
    else run("Duplicate...", " ");
    rename(newTitle);
}
