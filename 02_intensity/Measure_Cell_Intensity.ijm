// Cell intensity (MFI) workflow: background-subtracted fluorescence (e.g. GFP), control vs treated or on its own.
//
//   1. Choose: "Control vs treated" (pick the control folder, then one or more treated folders, e.g. a dose
//      series) or "Absolute MFI" (one file or one folder). A folder may hold the images directly or one subfolder per replicate (Rep1, Rep2, ...).
//      Any Bio-Formats format (.czi, .oir, .lif, .nd2, OME-TIFF ...). Measure RAW images, not deconvolved ones.
//      Channel default: the channel named like GFP/FITC/488, else channel 1; for colour-camera (RGB) files, the
//      green component.
//   2. Per image: background = median of the pixels below the image's Otsu threshold (5th percentile if the field
//      is nearly full of cells); the image is background-subtracted (z-stacks are projected first).
//   3. Threshold: every ImageJ auto-threshold method is run on the control images (all images in absolute mode)
//      and scored as signal kept x (1 - noise): signal kept = share of the net fluorescence inside the positive
//      area; noise = share of the positive area that is background noise (estimated from the pixels below -T,
//      since background noise is symmetric around 0 after subtraction).
//      The best one is suggested in a live window: yellow outlines of what will be measured follow the value
//      as you type, move the slider or pick another method. Outlines are found on a copy smoothed with a
//      1-pixel Gaussian (holes filled); intensities are always measured on the raw pixels.
//      The chosen value is then applied UNCHANGED to every image, treated included: a per-image auto-threshold would move with brightness and hide the cells that dim below it.
//   4. Readouts per image: MFI of positive objects (area-weighted, or the mean of N random objects per image),
//      % positive area, and field mean (whole image, no threshold, the cross-check). Without a nuclear or cell
//      stain, touching cells merge into one object, so 'objects' are not exact cell counts.
//   5. Writes cell_intensity_results.xlsx (Summary with treated/control ratio and % change, Replicates, Images,
//      Cells, Threshold methods, Settings), bar graphs (control vs treated) and qc/ overlays of what was measured.
//      Statistics use replicate means when every condition has >= 2 replicate subfolders, otherwise image means;
//      never pooled cells (cells from one dish are not independent samples).

// ---- settings ----
interactive = true;          // false = use the defaults below without dialogs (testing)
// ------------------

requires("1.54");
setOption("BlackBackground", true);

// ---- 1. what to measure ----
modes = newArray("Control vs treated (one or more treated folders, e.g. doses)", "Absolute MFI (no comparison)");
inputs = newArray("A folder", "One file");
mode = modes[0]; input = inputs[0];
if (interactive) {
    Dialog.create("Cell intensity");
    Dialog.addRadioButtonGroup("Analysis", modes, 2, 1, mode);
    Dialog.addMessage("Control vs treated: you will pick the control folder, then a treated folder; you can then add\n"
        + "more treated folders (other doses or drugs). All share the control's threshold and one graph.\n"
        + "Absolute MFI: measure one file or one folder on its own.\n"
        + "A folder can hold the images directly or one subfolder per replicate. Use raw images, not deconvolved ones.");
    Dialog.show();
    mode = Dialog.getRadioButton();
    if (mode == modes[1]) {
        Dialog.create("Cell intensity: absolute MFI");
        Dialog.addRadioButtonGroup("Measure", inputs, 1, 2, input);
        Dialog.show();
        input = Dialog.getRadioButton();
    }
}
compare = false; if (mode == modes[0]) compare = true;
fPath = newArray(); fCond = newArray(); fRep = newArray();
if (compare) {
    ctrlDir = getDirectory("Select the CONTROL folder");
    dirs = newArray(ctrlDir);
    trtDir = getDirectory("Select a TREATED folder");
    dirs = Array.concat(dirs, trtDir);
    while (interactive) {
        more = getBoolean("" + (dirs.length - 1) + " treated folder(s) selected.\nAdd another treated folder (another dose or drug)?", "Add another", "No, continue");
        if (!more) break;
        d = getDirectory("Select TREATED folder " + dirs.length);
        dirs = Array.concat(dirs, d);
    }
    condNames = newArray(dirs.length);
    dup = false;
    for (g = 0; g < dirs.length; g++) {
        condNames[g] = folderName(dirs[g]);
        for (h = 0; h < g; h++) {
            same = sameFolder(dirs[g], dirs[h]);
            if (same) exit("The same folder was selected twice:\n" + dirs[g]);
            if (condNames[g] == condNames[h]) dup = true;
        }
    }
    if (dup) { condNames[0] = "Control"; for (g = 1; g < dirs.length; g++) condNames[g] = "Treated " + g; }
    for (g = 0; g < dirs.length; g++) {
        list = collect(dirs[g]);
        if (list.length == 0) exit("No microscope files in\n" + dirs[g]);
        for (i = 0; i < list.length; i++) {
            f = split(list[i], "\t");
            fRep = Array.concat(fRep, f[0]); fPath = Array.concat(fPath, f[1]); fCond = Array.concat(fCond, g);
        }
    }
} else {
    if (input == inputs[1]) {
        onePath = File.openDialog("Select the image file");
        list = newArray("-\t" + onePath);
        n0 = File.getNameWithoutExtension(onePath);
        if (endsWith(n0, ".ome")) n0 = substring(n0, 0, lengthOf(n0) - 4);
        condNames = newArray(n0);
    } else {
        absDir = getDirectory("Select the image folder");
        list = collect(absDir);
        n0 = folderName(absDir);
        condNames = newArray(n0);
    }
    if (list.length == 0) exit("No microscope files found.");
    for (i = 0; i < list.length; i++) {
        f = split(list[i], "\t");
        fRep = Array.concat(fRep, f[0]); fPath = Array.concat(fPath, f[1]); fCond = Array.concat(fCond, 0);
    }
}
outDir = getDirectory("Choose a folder for the results");
nCond = condNames.length;

// ---- 2. options (channels read from the first file) ----
lines = split(readMetadata(fPath[0]), "\n");
if (startsWith(lines[0], "E")) exit(File.getName(fPath[0]) + " could not be read; it is used to read the channel names.");
// A colour (RGB) camera image opens as 3 channels whose names come from the filter (e.g. all "EGFP"); they are
// the colour components, so they are labelled as such and the green one is the default (GFP, FITC ...).
chNames = newArray(); anyZ = false; rgb = false;
for (i = 0; i < lines.length; i++) {
    f = split(lines[i], "\t");
    if (f[0] == "S") { if (parseInt(f[4]) > 1) anyZ = true; if (parseInt(f[1]) == 0) { if (parseInt(f[12]) == 3) rgb = true; } }
    if (f[0] == "C") { if (parseInt(f[1]) == 0) chNames = Array.concat(chNames, "C" + (parseInt(f[2]) + 1) + " " + f[3]); }
}
// Default channel: the first whose name looks like GFP (GFP, EGFP, FITC, 488), else channel 1.
measureCh = chNames[0];
for (i = chNames.length - 1; i >= 0; i--) if (matches(toUpperCase(chNames[i]), ".*(GFP|FITC|488).*")) measureCh = chNames[i];
if (rgb) { chNames = newArray("C1 (colour component 1)", "C2 green (colour camera)", "C3 (colour component 3)"); measureCh = chNames[1]; }
projections = newArray("Max Intensity", "Sum Slices", "Average Intensity");
projection = "Max Intensity";
minArea = 30;          // um^2 (pixels if the files are uncalibrated)
sampleN = 0;           // 0 = all objects
seed = 42;
if (interactive) {
    Dialog.create("Cell intensity: options");
    if (compare) {
        for (g = 0; g < nCond; g++) {
            nf = countOf(fCond, g);
            label = "Control name"; if (g > 0) label = "Treated " + g + " name";
            Dialog.addString(label, condNames[g], 20);
            Dialog.addToSameRow(); Dialog.addMessage("(" + nf + " files)");
        }
    } else Dialog.addMessage("" + fPath.length + " file(s)");
    if (rgb) Dialog.addMessage("These are colour-camera images: GFP is in the green component (C2).");
    Dialog.addChoice("Measure channel", chNames, measureCh);
    if (anyZ) Dialog.addChoice("Z-stacks: project with", projections, projection);
    Dialog.addNumber("Minimum object area", minArea, 0, 6, "um2 (smaller objects ignored)");
    Dialog.addNumber("Random objects per image", sampleN, 0, 6, "(0 = measure all)");
    Dialog.addNumber("Random seed", seed, 0, 6, "(same seed = same sample)");
    Dialog.show();
    if (compare) for (g = 0; g < nCond; g++) condNames[g] = Dialog.getString();
    measureCh = Dialog.getChoice();
    if (anyZ) projection = Dialog.getChoice();
    minArea = Dialog.getNumber(); sampleN = Dialog.getNumber(); seed = Dialog.getNumber();
}
for (c = 0; c < nCond; c++) condNames[c] = replace(condNames[c], "[,{}|'\t]", " ");
ch = parseInt(substring(measureCh, 1, indexOf(measureCh, " ")));
qcDir = outDir + "qc" + File.separator;
File.makeDirectory(qcDir);
setBatchMode(true);
skipped = "";

// ---- 3. threshold: score every method on the reference images (controls, or all in absolute mode) ----
methods = getList("threshold.methods");
nM = methods.length; NB = 1024;
refT = newArray(); hv = newArray(); hc = newArray(); nRef = 0; nPrev = 0; maxV = 0;
for (fi = 0; fi < fPath.length; fi++) {
    if (fCond[fi] != 0) continue;
    use = usableSeries(fPath[fi]);
    for (u = 0; u < use.length; u++) {
        s = use[u];
        if (s < 0) { if (s == -1) skipped = skipped + File.getName(fPath[fi]) + " is damaged (could not be read)\n"; continue; }
        err = loadChannel(fPath[fi], s, ch, projection);
        if (err != "") { skipped = skipped + File.getName(fPath[fi]) + ": " + err + "\n"; continue; }
        bg = background();
        run("Subtract...", "value=" + bg);
        smoothCopy("img", "smooth");
        close("img");
        selectWindow("smooth");
        for (m = 0; m < nM; m++) {
            setAutoThreshold(methods[m] + " dark");
            getThreshold(lo, hi);
            refT = Array.concat(refT, lo);
        }
        resetThreshold();
        getHistogram(values, counts, NB);
        hv = Array.concat(hv, values); hc = Array.concat(hc, counts);
        maxV = maxOf(maxV, values[NB - 1]);
        nRef++;
        if (nPrev < 6) { nPrev++; rename("ref" + nPrev); } else close("smooth");
    }
}
if (nRef == 0) exit("None of the " + condNames[0] + " images could be read.\n" + skipped);
mT = newArray(nM); mScore = newArray(nM); mPct = newArray(nM); mSig = newArray(nM); mNoise = newArray(nM);
for (m = 0; m < nM; m++) {
    t = newArray(nRef);
    for (r = 0; r < nRef; r++) t[r] = refT[r * nM + m];
    mT[m] = medianOf(t);
    for (r = 0; r < nRef; r++) {
        st = scoreThreshold(hv, hc, r * NB, NB, mT[m]);
        mScore[m] += st[0] / nRef; mPct[m] += st[1] / nRef; mSig[m] += st[2] / nRef; mNoise[m] += st[3] / nRef;
    }
}
order = Array.rankPositions(mScore); order = Array.reverse(order);
labels = newArray(nM); ordT = newArray(nM);
for (k = 0; k < nM; k++) {
    m = order[k]; ordT[k] = mT[m];
    labels[k] = methods[m] + ":  " + d2s(mT[m], 1) + "   signal kept " + d2s(100 * mSig[m], 0) + "%, noise " + d2s(100 * mNoise[m], 1) + "%, " + d2s(mPct[m], 1) + "% area positive";
    if (k == 0) labels[k] = labels[k] + "  (best)";
}
T = ordT[0]; method = methods[order[0]];
if (nPrev > 1) run("Images to Stack", "method=[Copy (center)] name=preview title=ref use");
else { selectWindow("ref1"); rename("preview"); }
if (interactive) {
    selectWindow("preview");
    run("Grays");
    run("Enhance Contrast", "saturated=0.35");
    setBatchMode("show");
    msg = "Every threshold method was tried on " + nRef + " " + condNames[0] + " image(s) (background-subtracted).\n"
        + "Ranked by signal kept x (1 - noise): signal kept = share of the signal inside the positive area;\n"
        + "noise = share of the positive area that is background noise. Top = best.\n"
        + "Yellow outlines = what will be measured: they should surround the cells, not the background.\n"
        + "Type a value, move the slider or pick a method; scroll the image to check the other control images.\n"
        + "This one value is applied to every image.";
    r = thresholdDialog("Cell intensity: threshold", msg, labels, ordT, maxV);
    if (r == "cancel") exit;
    if (startsWith(r, "ERR")) exit("Threshold window failed: " + r);
    f = split(r, "\t"); T = parseFloat(f[0]); method = methods[order[parseInt(f[1])]];
    if (f[2] == "1") method = method + " (edited)";
}
close("preview");
print("Fixed threshold: " + T + " (" + method + ", from " + nRef + " images)");
methodRows = "Method\tThreshold (bg-subtracted)\tScore\tSignal kept (%)\tNoise in positive area (%)\tPositive area (%)\n";
for (k = 0; k < nM; k++) { m = order[k]; methodRows = methodRows + methods[m] + "\t" + d2s(mT[m], 3) + "\t" + d2s(mScore[m], 4) + "\t" + d2s(100 * mSig[m], 2) + "\t" + d2s(100 * mNoise[m], 3) + "\t" + d2s(mPct[m], 3) + "\n"; }

// ---- 4. measure every image ----
cellRows = "Condition\tReplicate\tFile\tSeries\tObject\tArea\tMFI (bg-subtracted)\tIntegrated intensity\tIn random sample\n";
iCond = newArray(); iRep = newArray(); iFile = newArray(); iSer = newArray(); iBg = newArray(); iN = newArray();
iPct = newArray(); iMfiAll = newArray(); iMfi = newArray(); iField = newArray();
areaUnit = "";
for (fi = 0; fi < fPath.length; fi++) {
    use = usableSeries(fPath[fi]);
    for (u = 0; u < use.length; u++) {
        s = use[u];
        if (s < 0) { if (s == -1 && fCond[fi] != 0) skipped = skipped + File.getName(fPath[fi]) + " is damaged (could not be read)\n"; continue; }
        err = loadChannel(fPath[fi], s, ch, projection);
        if (err != "") { if (fCond[fi] != 0) skipped = skipped + File.getName(fPath[fi]) + ": " + err + "\n"; continue; }
        bg = background();
        run("Subtract...", "value=" + bg);
        getPixelSize(unit, pw, ph);
        if (areaUnit == "") areaUnit = unit + "^2";
        fieldArea = getWidth() * getHeight() * pw * ph;
        getStatistics(a, fieldMean);
        makeMask("img", T);
        run("Set Measurements...", "area mean integrated redirect=img decimal=4");
        selectWindow("mask");
        run("Analyze Particles...", "size=" + minArea + "-Infinity show=Masks display clear");
        rename("measured");
        run("Set Measurements...", "area mean integrated redirect=None decimal=4");   // no redirect left behind
        n = nResults;
        area = newArray(n); mean = newArray(n); intd = newArray(n);
        sumA = 0; sumAM = 0;
        for (r = 0; r < n; r++) {
            area[r] = getResult("Area", r); mean[r] = getResult("Mean", r); intd[r] = getResult("IntDen", r);
            sumA += area[r]; sumAM += area[r] * mean[r];
        }
        run("Clear Results");
        seedHere = seed + fi * 100 + s;
        flags = sampleFlags(n, sampleN, seedHere);
        sumS = 0; nS = 0;
        name = File.getName(fPath[fi]);
        cname = condNames[fCond[fi]];
        for (r = 0; r < n; r++) {
            inS = "yes"; if (flags[r] == 0) inS = "no";
            if (flags[r] == 1) { sumS += mean[r]; nS++; }
            cellRows = cellRows + cname + "\t" + fRep[fi] + "\t" + name + "\t" + (s + 1) + "\t" + (r + 1) + "\t"
                + d2s(area[r], 3) + "\t" + d2s(mean[r], 3) + "\t" + d2s(intd[r], 1) + "\t" + inS + "\n";
        }
        mfiAll = NaN; if (sumA > 0) mfiAll = sumAM / sumA;
        mfiS = NaN; if (nS > 0) mfiS = sumS / nS;
        iCond = Array.concat(iCond, fCond[fi]); iRep = Array.concat(iRep, fRep[fi]); iFile = Array.concat(iFile, name);
        iSer = Array.concat(iSer, s + 1); iBg = Array.concat(iBg, bg); iN = Array.concat(iN, n);
        iPct = Array.concat(iPct, 100 * sumA / fieldArea); iMfiAll = Array.concat(iMfiAll, mfiAll); iField = Array.concat(iField, fieldMean);
        if (sampleN > 0) iMfi = Array.concat(iMfi, mfiS); else iMfi = Array.concat(iMfi, mfiAll);
        base = File.getNameWithoutExtension(name);
        if (endsWith(base, ".ome")) base = substring(base, 0, lengthOf(base) - 4);
        qcName = cname + "_" + fRep[fi] + "_" + base;
        qcName = sanitize(qcName);
        if (use.length > 1) qcName = qcName + "_S" + (s + 1);
        qcFile = qcDir + qcName + "_qc.png";
        qcOverlay("img", "measured", qcFile);
        close("*");
        print(cname + " / " + name + ": " + n + " objects, MFI " + d2s(mfiAll, 1) + ", positive " + d2s(100 * sumA / fieldArea, 1) + "%");
    }
}
if (isOpen("Results")) { selectWindow("Results"); run("Close"); }
if (iCond.length == 0) exit("No image could be measured.\n" + skipped);

// ---- 5. tables ----
useReps = compare;
for (c = 0; c < nCond; c++) if (repCount(iRep, iCond, c) < 2) useReps = false;
unitName = "images"; if (useReps) unitName = "replicates";
mfiName = "MFI of positive objects"; if (sampleN > 0) mfiName = "MFI of " + sampleN + " random objects per image";
readouts = newArray(mfiName, "Positive area (%)", "Field mean (no threshold)", "Objects per image");
summary = "Readout\tCondition\tMean\tSD\tn (" + unitName + ")";
if (compare) summary = summary + "\tRelative to " + condNames[0] + "\tChange vs " + condNames[0] + " (%)";
summary = summary + "\n";
ctrlMean = newArray(4);
graphs = newArray();
for (k = 0; k < 4; k++) {
    if (k == 0) v = iMfi; if (k == 1) v = iPct; if (k == 2) v = iField; if (k == 3) v = iN;
    gMean = newArray(nCond); gSd = newArray(nCond); px = newArray(); py = newArray();
    for (c = 0; c < nCond; c++) {
        pts = unitValues(v, iCond, iRep, c, useReps);
        gm = NaN; gs = NaN;
        if (pts.length > 0) Array.getStatistics(pts, mn, mx, gm, gs);
        if (pts.length < 2) gs = NaN;
        gMean[c] = gm; gSd[c] = gs;
        for (i = 0; i < pts.length; i++) { px = Array.concat(px, c + 0.25 * (i - (pts.length - 1) / 2) / maxOf(1, pts.length - 1)); py = Array.concat(py, pts[i]); }
    }
    ctrlMean[k] = gMean[0];
    for (c = 0; c < nCond; c++) {
        nu = unitValues(v, iCond, iRep, c, useReps);
        summary = summary + readouts[k] + "\t" + condNames[c] + "\t" + d2s(gMean[c], 4) + "\t" + d2s(gSd[c], 4) + "\t" + nu.length;
        if (compare) summary = summary + "\t" + d2s(gMean[c] / gMean[0], 4) + "\t" + d2s(100 * (gMean[c] / gMean[0] - 1), 2);
        summary = summary + "\n";
    }
    if (compare && k < 3) {
        gFile = outDir + "bar_" + k + ".png";
        gFile = barGraph(readouts[k], condNames, gMean, gSd, px, py, unitName, gFile);
        graphs = Array.concat(graphs, gFile);
    }
}
imgRows = "Condition\tReplicate\tFile\tSeries\tBackground\tObjects\tPositive area (%)\tMFI of positive objects";
if (sampleN > 0) imgRows = imgRows + "\tMFI of random objects";
imgRows = imgRows + "\tField mean (no threshold)";
if (compare) imgRows = imgRows + "\tMFI / " + condNames[0] + " mean\tPositive area / " + condNames[0] + " mean\tField mean / " + condNames[0] + " mean";
imgRows = imgRows + "\n";
for (i = 0; i < iCond.length; i++) {
    imgRows = imgRows + condNames[iCond[i]] + "\t" + iRep[i] + "\t" + iFile[i] + "\t" + iSer[i] + "\t" + d2s(iBg[i], 3) + "\t" + iN[i] + "\t"
        + d2s(iPct[i], 4) + "\t" + d2s(iMfiAll[i], 4);
    if (sampleN > 0) imgRows = imgRows + "\t" + d2s(iMfi[i], 4);
    imgRows = imgRows + "\t" + d2s(iField[i], 4);
    if (compare) imgRows = imgRows + "\t" + d2s(iMfi[i] / ctrlMean[0], 4) + "\t" + d2s(iPct[i] / ctrlMean[1], 4) + "\t" + d2s(iField[i] / ctrlMean[2], 4);
    imgRows = imgRows + "\n";
}
repRows = "Condition\tReplicate\tImages\t" + mfiName + "\tPositive area (%)\tField mean (no threshold)\n";
for (c = 0; c < nCond; c++) {
    reps = newArray();
    for (i = 0; i < iCond.length; i++) if (iCond[i] == c) reps = Array.concat(reps, iRep[i]);
    reps = uniqueOf(reps);
    for (r = 0; r < reps.length; r++) {
        nn = 0; for (i = 0; i < iCond.length; i++) if (iCond[i] == c) { if (iRep[i] == reps[r]) nn++; }
        // means skip images without a value (e.g. no positive objects), as the Summary does
        repRows = repRows + condNames[c] + "\t" + reps[r] + "\t" + nn + "\t" + d2s(repMean(iMfi, iCond, iRep, c, reps[r]), 4)
            + "\t" + d2s(repMean(iPct, iCond, iRep, c, reps[r]), 4) + "\t" + d2s(repMean(iField, iCond, iRep, c, reps[r]), 4) + "\n";
    }
}
settings = "Setting\tValue\nAnalysis\t" + mode + "\n";
if (compare) for (g = 0; g < nCond; g++) settings = settings + condNames[g] + " folder\t" + dirs[g] + "\n";
else settings = settings + "Input\t" + fPath[0] + "\n";
settings = settings + "Measured channel\t" + measureCh + "\nZ-projection\t" + projection
    + "\nBackground\tmedian of pixels below each image's Otsu threshold (5th percentile if the field is >95% above it), subtracted"
    + "\nThreshold\t" + T + " (" + method + "; methods scored on " + nRef + " " + condNames[0] + " image(s), applied unchanged to all)"
    + "\nMethod score\tsignal kept x (1 - noise); signal kept = net intensity above T / total net intensity; noise = pixels below -T / pixels above T (background noise is symmetric around 0); mean over the scored images"
    + "\nMinimum object area\t" + minArea + " " + areaUnit + "\nRandom objects per image\t" + sampleN + " (0 = all), seed " + seed
    + "\nMFI of positive objects\tarea-weighted mean background-subtracted intensity of objects above the threshold"
    + "\nStatistics unit\t" + unitName + "\nImages measured\t" + iCond.length + "\n";
xlsx = outDir + "cell_intensity_results.xlsx";
err = writeXlsx(xlsx, newArray("Summary", "Replicates", "Images", "Cells", "Threshold methods", "Settings"),
    newArray(summary, repRows, imgRows, cellRows, methodRows, settings));
if (err != "") print("Excel file could not be written: " + err);
if (graphs.length > 0) {
    for (i = 0; i < graphs.length; i++) open(graphs[i]);
    run("Images to Stack", "name=graphs title=bar_ use");
    run("Make Montage...", "columns=" + graphs.length + " rows=1 scale=1 border=0");
    saveAs("PNG", outDir + "bar_graphs.png");
    close("*");
    for (i = 0; i < graphs.length; i++) ok = File.delete(graphs[i]);
}
setBatchMode(false);
done = "Measured " + iCond.length + " image(s); threshold " + d2s(T, 2) + " (" + method + ").\n \nResults:  " + xlsx;
if (graphs.length > 0) done = done + "\nBar graphs:  " + outDir + "bar_graphs.png";
done = done + "\nQC overlays:  " + qcDir + "\n \nStatistics use " + unitName + ", not pooled cells.";
if (skipped != "") done = done + "\n \nNot processed:\n" + skipped + "A file listed here that should match the others is most likely damaged.";
if (graphs.length > 0 && interactive) open(outDir + "bar_graphs.png");
print("Done. " + done);
if (interactive) showMessage("Cell intensity finished", done);

// ================= functions =================

// Opens series s, keeps channel ch (projected if a z-stack) as 32-bit image "img". Returns "" or the problem.
function loadChannel(path, s, ch, projection) {
    one = newArray(1); one[0] = ch;
    err = loadChannels(path, s, one, newArray("chan"));
    if (err != "") return err;
    selectWindow("chan");
    if (nSlices > 1) {
        run("Z Project...", "projection=[" + projection + "]");
        p = getTitle(); close("chan"); selectWindow(p);
    }
    rename("img");
    return "";
}

// Background of "img": median of the pixels below its Otsu threshold (5th percentile when nearly all is above).
function background() {
    selectWindow("img");
    setAutoThreshold("Otsu dark");
    getThreshold(lo, hi);
    resetThreshold();
    setThreshold(-1e30, lo);
    run("Create Selection");
    bg = NaN;
    if (selectionType() >= 0) {
        getRawStatistics(nBelow);
        List.setMeasurements;
        if (nBelow > 0.05 * getWidth() * getHeight()) bg = List.getValue("Median");
    }
    run("Select None"); resetThreshold();
    if (isNaN(bg)) bg = percentileOf("img", 5);
    return bg;
}

function percentileOf(title, p) {
    selectWindow(title);
    nBins = 4096;
    getHistogram(values, counts, nBins);
    total = 0; for (i = 0; i < nBins; i++) total += counts[i];
    acc = 0;
    for (i = 0; i < nBins; i++) { acc += counts[i]; if (acc >= total * p / 100) return values[i]; }
    return values[nBins - 1];
}

// Copy of title smoothed with a 1-pixel Gaussian: outlines are found on it (dim cell edges hover around the
// threshold pixel by pixel and would break into speckles); intensities are always measured on the raw image.
function smoothCopy(title, newTitle) {
    selectWindow(title);
    run("Duplicate...", "title=" + newTitle);
    run("Gaussian Blur...", "sigma=1");
}

// Binary "mask" of the (background-subtracted) image: smoothed pixels >= threshold, holes filled.
function makeMask(title, T) {
    smoothCopy(title, "mask");
    setThreshold(T, 1e30);
    run("Convert to Mask");
    run("Fill Holes");
}

// Autoscaled image with the outlines of the mask (objects = 255) in yellow, saved as PNG.
function qcOverlay(img, mask, file) {
    selectWindow(img);
    run("Duplicate...", "title=qcimg");
    run("Enhance Contrast", "saturated=0.35");
    run("8-bit"); run("RGB Color");
    selectWindow(mask);
    setThreshold(255, 255);
    run("Create Selection");
    if (selectionType() >= 0) {
        selectWindow("qcimg");
        run("Restore Selection");
        setForegroundColor(255, 220, 0);
        run("Line Width...", "line=" + maxOf(1, round(getWidth() / 700)));
        run("Draw", "slice");
        run("Select None");
    }
    selectWindow(mask); run("Select None");
    selectWindow("qcimg");
    saveAs("PNG", file);
    close();
}

// 1/0 flags: a reproducible random sample of k out of n (all when k <= 0 or k >= n).
function sampleFlags(n, k, seed) {
    flags = newArray(n);
    if (k <= 0 || k >= n) { for (i = 0; i < n; i++) flags[i] = 1; return flags; }
    random("seed", seed);
    idx = Array.getSequence(n);
    for (i = n - 1; i > 0; i--) { j = floor(random() * (i + 1)); t = idx[i]; idx[i] = idx[j]; idx[j] = t; }
    for (i = 0; i < k; i++) flags[idx[i]] = 1;
    return flags;
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

// Indices of the series to measure in a file (full-size, not time-lapse, readable); -1 = unreadable file,
// -2 = series excluded (pyramid level / time-lapse / unreadable plane).
function usableSeries(path) {
    lines = split(readMetadata(path), "\n");
    if (startsWith(lines[0], "E")) { bad = newArray(1); bad[0] = -1; return bad; }
    sx = newArray(); st = newArray(); sok = newArray();
    for (i = 0; i < lines.length; i++) {
        f = split(lines[i], "\t");
        if (f[0] != "S") continue;
        k = parseInt(f[1]); sx[k] = parseInt(f[3]); st[k] = parseInt(f[10]); sok[k] = parseInt(f[11]);
    }
    maxX = 0;
    for (k = 0; k < sx.length; k++) maxX = maxOf(maxX, sx[k]);
    out = newArray();
    for (k = 0; k < sx.length; k++) {
        if (sx[k] < maxX / 2 || st[k] > 1 || sok[k] == 0) out = Array.concat(out, -2);
        else out = Array.concat(out, k);
    }
    return out;
}

function uniqueOf(a) {
    out = newArray();
    for (i = 0; i < a.length; i++) {
        seen = false;
        for (j = 0; j < out.length; j++) if (out[j] == a[i]) seen = true;
        if (!seen) out = Array.concat(out, a[i]);
    }
    return out;
}

function medianOf(a) {
    b = Array.copy(a); Array.sort(b);
    n = b.length;
    if (n % 2 == 1) return b[floor(n / 2)];
    return (b[n / 2 - 1] + b[n / 2]) / 2;
}

// Microscope files in dir and in its subfolders (one level; the subfolder name is the replicate): "rep<tab>path".
// Output folders of these workflows (deconvolved, qc, figures) are not replicates and are skipped.
function collect(dir) {
    out = newArray();
    list = getFileList(dir); Array.sort(list);
    for (i = 0; i < list.length; i++) {
        lower = toLowerCase(list[i]);
        if (lower == "deconvolved/" || lower == "qc/" || lower == "figures/") continue;
        if (endsWith(list[i], "/")) {
            rep = substring(list[i], 0, lengthOf(list[i]) - 1);
            inner = getFileList(dir + list[i]); Array.sort(inner);
            for (j = 0; j < inner.length; j++) if (isMicroscopeFile(inner[j])) out = Array.concat(out, rep + "\t" + dir + list[i] + inner[j]);
        } else if (isMicroscopeFile(list[i])) out = Array.concat(out, "-\t" + dir + list[i]);
    }
    return out;
}

function folderName(dir) {
    d = replace(dir, "\\\\", "/");
    if (endsWith(d, "/")) d = substring(d, 0, lengthOf(d) - 1);
    return File.getName(d);
}

function countOf(a, x) {
    n = 0;
    for (i = 0; i < a.length; i++) if (a[i] == x) n++;
    return n;
}

// Number of real replicate subfolders (not "-") among the measured images of condition c.
function repCount(iRep, iCond, c) {
    reps = newArray();
    for (i = 0; i < iCond.length; i++) if (iCond[i] == c) { if (iRep[i] != "-") reps = Array.concat(reps, iRep[i]); }
    reps = uniqueOf(reps);
    return reps.length;
}

// The statistical units of condition c: replicate means (useReps) or image values; NaN skipped.
function unitValues(v, iCond, iRep, c, useReps) {
    out = newArray();
    if (!useReps) {
        for (i = 0; i < v.length; i++) if (iCond[i] == c) { if (!isNaN(v[i])) out = Array.concat(out, v[i]); }
        return out;
    }
    reps = newArray();
    for (i = 0; i < v.length; i++) if (iCond[i] == c) reps = Array.concat(reps, iRep[i]);
    reps = uniqueOf(reps);
    for (r = 0; r < reps.length; r++) {
        sum = 0; n = 0;
        for (i = 0; i < v.length; i++) if (iCond[i] == c) { if (iRep[i] == reps[r] && !isNaN(v[i])) { sum += v[i]; n++; } }
        if (n > 0) out = Array.concat(out, sum / n);
    }
    return out;
}

// Mean of v over the images of condition c and replicate rep (NaN skipped).
function repMean(v, iCond, iRep, c, rep) {
    sum = 0; n = 0;
    for (i = 0; i < v.length; i++) if (iCond[i] == c) { if (iRep[i] == rep && !isNaN(v[i])) { sum += v[i]; n++; } }
    if (n == 0) return NaN;
    return sum / n;
}

// Scores threshold T on one background-subtracted image's histogram (bins off .. off+nb-1 of hv/hc).
// Background noise is symmetric around 0, so the pixels below -T estimate the noise pixels above +T.
//   noise  = (pixels <= -T) / (pixels >= T)              share of the positive pixels that are noise
//   signal = (sum of x >= T + sum of x <= -T) / sum of x  share of the net signal kept (noise sums to ~0)
//   score  = signal * (1 - noise)
// Returns [score, % positive area, signal, noise].
function scoreThreshold(hv, hc, off, nb, T) {
    N = 0; tot = 0; nF = 0; nN = 0; cap = 0;
    half = (hv[off + 1] - hv[off]) / 2;
    for (i = off; i < off + nb; i++) {
        x = hv[i] + half; c = hc[i];
        N += c; tot += c * x;
        if (x >= T) { nF += c; cap += c * x; }
        if (x <= -T) { nN += c; cap += c * x; }
    }
    if (T <= 0 || nF == 0 || tot <= 0) return newArray(0, 100 * nF / N, 0, 1);
    noise = minOf(1, nN / nF);
    signal = minOf(1, maxOf(0, cap / tot));
    return newArray(signal * (1 - noise), 100 * nF / N, signal, noise);
}

// Live threshold window for the image "preview" (titled title): the yellow outlines follows the typed value, the slider and the
// method list. Returns "value<tab>index of the chosen method<tab>1 if the value was edited, else 0" (an unedited
// value is the method's exact threshold, not the rounded one the field shows), "cancel", or "ERR ...".
function thresholdDialog(title, msg, labels, vals, maxV) {
    l = ""; v = "";
    for (i = 0; i < labels.length; i++) { l = l + replace(labels[i], "['|]", "") + "|"; v = v + d2s(vals[i], 9) + ","; }
    msg = replace(msg, "'", ""); title = replace(title, "'", "");
    msg = replace(msg, "\n", "\\n");
    js = "try { var imp = Packages.ij.WindowManager.getImage('preview'); var L = '" + l + "'.split('|'); L.pop(); var vals = [" + v + "];"
       + "var gd = new Packages.ij.gui.NonBlockingGenericDialog('" + title + "');"
       + "gd.addMessage('" + msg + "');"
       + "gd.addChoice('Method', L, L[0]);"
       + "gd.addSlider('Threshold', 0, " + maxV + ", vals[0], " + (maxV / 1000) + ");"
       + "var cur = vals[0], last = imp.getCurrentSlice();"
       + "function show(t) { cur = t; var ip = imp.getProcessor(); ip.setThreshold(t, 1e30, Packages.ij.process.ImageProcessor.NO_LUT_UPDATE);"
       + "  var roi = new Packages.ij.plugin.filter.ThresholdToSelection().convert(ip); ip.resetThreshold(); var ov = new Packages.ij.gui.Overlay();"
       + "  if (roi != null) { roi.setStrokeColor(java.awt.Color.YELLOW); ov.add(roi); } imp.setOverlay(ov); }"
       + "var lis = new Packages.ij.ImageListener({ imageOpened: function (i) {}, imageClosed: function (i) {},"
       + "  imageUpdated: function (i) { if (i == imp && imp.getCurrentSlice() != last) { last = imp.getCurrentSlice(); show(cur); } } });"
       + "Packages.ij.ImagePlus.addImageListener(lis); show(vals[0]);"
       + "gd.addDialogListener(new Packages.ij.gui.DialogListener({ dialogItemChanged: function (g, e) {"
       + "  var ch = g.getChoices().get(0); var tf = g.getNumericFields().get(0);"
       + "  if (e != null && e.getSource() == ch) tf.setText(String(vals[ch.getSelectedIndex()]));"
       + "  var t = parseFloat(tf.getText()); if (!isNaN(t)) show(t); return true; } }));"
       + "var w = imp.getWindow(); var ss = java.awt.Toolkit.getDefaultToolkit().getScreenSize(); var sw = ss.width, sh = ss.height;"
       + "if (w != null) { var z = Math.min(1, Math.min(0.55 * sw / imp.getWidth(), 0.8 * sh / imp.getHeight()));"
       + "  var cv = imp.getCanvas(); var guard = 0; while (cv.getMagnification() > z + 1e-6 && guard++ < 20) cv.zoomOut(Math.floor(imp.getWidth() / 2), Math.floor(imp.getHeight() / 2));"
       + "  w = imp.getWindow(); w.setLocation(0, 0); gd.pack(); gd.centerDialog(false); gd.setLocation(Math.max(0, Math.min(w.getWidth() + 10, sw - gd.getWidth())), 0); }"
       + "gd.showDialog(); var out = 'cancel';"
       + "if (!gd.wasCanceled()) { var k = gd.getNextChoiceIndex(), t = gd.getNextNumber();"
       + "  var edited = Math.abs(t - vals[k]) > " + (maxV / 1000) + ";"   // the field shows a rounded value: within a step = unchanged
       + "  out = (edited ? t : vals[k]) + '\\t' + k + '\\t' + (edited ? 1 : 0); }"
       + "Packages.ij.ImagePlus.removeImageListener(lis); imp.setOverlay(null); out; } catch (e) { 'ERR ' + e; }";
    return eval("js", js);
}

// Bar graph (mean, SD error bars, one dot per statistical unit) of the conditions, saved as a PNG; returns its path.
function barGraph(title, names, means, sds, px, py, unitName, file) {
    hi = 0; lo = 0;
    for (i = 0; i < py.length; i++) { hi = maxOf(hi, py[i]); lo = minOf(lo, py[i]); }
    e = newArray(sds.length);
    for (i = 0; i < sds.length; i++) { e[i] = sds[i]; if (isNaN(e[i])) e[i] = 0; hi = maxOf(hi, means[i] + e[i]); }
    n = names.length;
    Plot.create("bar_" + title, "{" + String.join(names, ",") + "}", title);
    Plot.setLimits(-0.6, n - 0.4, lo * 1.15, hi * 1.15);
    Plot.setFrameSize(maxOf(260, 110 * n), 260);
    Plot.setColor("#12294A", "#9DB4D6");
    Plot.add("separated bar", Array.getSequence(n), means);
    Plot.setColor("black");
    Plot.add("error bars", e);
    Plot.setColor("#E2552D", "#E2552D");
    Plot.add("circle", px, py);
    Plot.setColor("black");
    Plot.addText("mean +/- SD; dots = " + unitName, 0.02, 0.06);
    Plot.show();
    saveAs("PNG", file);
    close();
    return file;
}

// Writes tab-separated tables as the sheets of an .xlsx workbook (numbers as numbers, header row frozen).
// Returns "" or the error.
function writeXlsx(path, names, contents) {
    tmp = getDirectory("temp");
    files = "";
    for (i = 0; i < names.length; i++) {
        f = tmp + "sheet" + i + ".tsv";
        File.saveString(contents[i], f);
        files = files + jsText(f) + "|";
        names[i] = replace(names[i], "[|'\\[\\]:*?/\\\\]", " ");
    }
    p = jsText(path);
    js = "try { var Z = java.util.zip; var out = new Z.ZipOutputStream(new java.io.FileOutputStream('" + p + "'));"
       + "function put(n, t) { out.putNextEntry(new Z.ZipEntry(n)); var b = new java.lang.String(t).getBytes('UTF-8'); out.write(b, 0, b.length); out.closeEntry(); }"
       + "function esc(s) { return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/\"/g, '&quot;'); }"
       + "function col(i) { var s = ''; i++; while (i > 0) { var m = (i - 1) % 26; s = String.fromCharCode(65 + m) + s; i = Math.floor((i - 1) / 26); } return s; }"
       + "var names = '" + String.join(names, "|") + "'.split('|'); var files = '" + files + "'.split('|');"
       + "var NS = 'http://schemas.openxmlformats.org/'; var ct = '', wb = '', rel = '';"
       + "for (var s = 0; s < names.length; s++) {"
       + "  var lines = java.nio.file.Files.readAllLines(java.nio.file.Paths.get(files[s]), java.nio.charset.StandardCharsets.UTF_8); var rows = [];"
       + "  for (var r = 0; r < lines.size(); r++) { var f = String(lines.get(r)).split('\\t'); var cells = [];"
       + "    for (var c = 0; c < f.length; c++) { var x = f[c], ref = col(c) + (r + 1);"
       + "      if (x == '' || x == 'NaN') continue;"
       + "      if (/^-?[0-9]+(\\.[0-9]+)?([eE]-?[0-9]+)?$/.test(x)) cells.push('<c r=\"' + ref + '\"><v>' + x + '</v></c>');"
       + "      else cells.push('<c r=\"' + ref + '\" t=\"inlineStr\"><is><t>' + esc(x) + '</t></is></c>'); }"
       + "    rows.push('<row r=\"' + (r + 1) + '\">' + cells.join('') + '</row>'); }"
       + "  put('xl/worksheets/sheet' + (s + 1) + '.xml', '<?xml version=\"1.0\" encoding=\"UTF-8\"?><worksheet xmlns=\"' + NS + 'spreadsheetml/2006/main\">'"
       + "    + '<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews>'"
       + "    + '<cols><col min=\"1\" max=\"30\" width=\"18\" customWidth=\"1\"/></cols><sheetData>' + rows.join('') + '</sheetData></worksheet>');"
       + "  ct += '<Override PartName=\"/xl/worksheets/sheet' + (s + 1) + '.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>';"
       + "  wb += '<sheet name=\"' + esc(names[s]) + '\" sheetId=\"' + (s + 1) + '\" r:id=\"rId' + (s + 1) + '\"/>';"
       + "  rel += '<Relationship Id=\"rId' + (s + 1) + '\" Type=\"' + NS + 'officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet' + (s + 1) + '.xml\"/>'; }"
       + "put('[Content_Types].xml', '<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"' + NS + 'package/2006/content-types\">'"
       + "  + '<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>'"
       + "  + '<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>' + ct + '</Types>');"
       + "put('_rels/.rels', '<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"' + NS + 'package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"' + NS + 'officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>');"
       + "put('xl/workbook.xml', '<?xml version=\"1.0\" encoding=\"UTF-8\"?><workbook xmlns=\"' + NS + 'spreadsheetml/2006/main\" xmlns:r=\"' + NS + 'officeDocument/2006/relationships\"><sheets>' + wb + '</sheets></workbook>');"
       + "put('xl/_rels/workbook.xml.rels', '<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"' + NS + 'package/2006/relationships\">' + rel + '</Relationships>');"
       + "out.close(); ''; } catch (e) { String(e); }";
    err = eval("js", js);
    for (i = 0; i < names.length; i++) { f = tmp + "sheet" + i + ".tsv"; if (File.exists(f)) ok = File.delete(f); }
    return err;
}

// Opens series s and keeps the given channels (1-based) as 32-bit images or stacks with the given titles
// (calibration kept). Returns "" or the problem.
function loadChannels(path, s, chs, titles) {
    err = openSeries(path, s);
    if (err != "") return "could not be opened (" + shortError(err, path) + ")";
    src = getTitle();
    getDimensions(w, h, c, z, t);
    for (i = 0; i < chs.length; i++) if (c < chs[i]) { close(src); return "has only " + c + " channel(s)"; }
    getPixelSize(unit, pw, ph);
    if (unit == "pixel" || unit == "pixels" || unit == "") { close(src); return "has no pixel size (uncalibrated: set it in Image > Properties and save, or use the original microscope file)"; }
    for (i = 0; i < chs.length; i++) {
        selectWindow(src);
        run("Duplicate...", "title=" + titles[i] + " duplicate channels=" + chs[i]);
        run("32-bit");
    }
    close(src);
    return "";
}
