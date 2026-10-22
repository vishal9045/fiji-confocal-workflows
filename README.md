# Fiji confocal workflows

Guided workflows for confocal image analysis in Fiji. A single file can be any format Bio-Formats reads; in a folder, the workflows pick up the common microscope formats (Olympus .oir/.oib/.oif, Zeiss .czi/.lsm/.zvi, Leica .lif/.lof, Nikon .nd2, Imaris .ims, Olympus .vsi, DeltaVision .dv, .ics and TIFF/OME-TIFF). Each workflow asks for its folders, channels and settings in dialogs, and shows a live preview for the main threshold or cutoff. The measurement workflows write an Excel workbook (summary, per-image and per-cell or per-piece sheets, and the settings used) and QC images, plus bar graphs when you compare conditions. Nothing needs installing beyond Fiji itself.

## Install
Download [`Confocal_Workflows.jar`](Confocal_Workflows.jar) (the download button is on that page), drag it onto the Fiji window (or copy it into `Fiji.app/plugins/`) and restart Fiji. The workflows appear under Plugins › Confocal Workflows. To update, replace the jar. If you installed loose `.ijm` copies earlier, delete them, or each workflow will be listed twice. Plugins › Confocal Workflows › About Confocal Workflows shows the installed version, and every results workbook records it in its Settings sheet.

## Deconvolve Confocal Stack
For 60x/100x confocal stacks. Give it one file or a whole folder and pick the series. The workflow reads the optics from the file, checks Nyquist sampling and runs a trial on each channel (a montage with contrast and noise) before Richardson-Lucy deconvolution; nuclear channels (DAPI, Hoechst) skip the trial and get a fixed 10 iterations. It saves calibrated TIFFs, QC images, a methods manifest (CSV) and, unless you turn them off, figures: per-channel panels and merges, with one display range per channel across all images. "Figures only" remakes the figures from an earlier run, and setting every channel to "raw" makes figures without deconvolving.

## Measure Cell Intensity
Measures fluorescence intensity, for example GFP, on raw (not deconvolved) images. Choose Control vs treated (pick the control folder, then one or more treated folders, such as a dose series) or Absolute MFI (one file or one folder). A folder can hold the images directly or one subfolder per replicate. The channel defaults to the one named like GFP, FITC or 488; colour-camera (RGB) files default to their green component.

Every ImageJ threshold method is scored on the control images (signal kept × (1 − noise)), and the best one is suggested in a live window. Yellow outlines show what will be measured and follow the value as you type, drag or pick a method. That one threshold is then applied to every image, and objects smaller than 30 µm² are left out. Each image is background-subtracted and reported as the MFI of positive objects (optionally a reproducible random N per image), the percent positive area, and the threshold-free mean of the whole field.

Results go to `cell_intensity_results.xlsx` (a summary with each condition relative to control and as % change, plus replicates, images, cells, threshold methods and settings), with bar graphs of all conditions (when comparing) and QC overlays of what was measured.

## Mitochondrial Measurements
Counts mitochondrial pieces and measures their length, with any mitochondrial marker or dye. Pick the mitochondrial channel in the dialog (the default is the first channel). Choose Control vs treated (control folder, then one or more treated folders) or Absolute (one file or folder, optionally within regions or single cells you outline). Each image is background-subtracted (rolling ball) and outlined with one threshold for all images (Otsu by default, adjustable in a live window). Small holes are filled, so the rings that outer-membrane markers such as TOM20 and TOM70 give around swollen mitochondria are not measured as loops.

The main readout is length per piece: total skeleton length divided by the number of pieces. Mean branch length, number of pieces, and mean area and perimeter per piece are reported too. The optional 2D + 3D mode repeats the measurements on the full stack next to the max projection, with a warning about z-sampling. Results go to `mitochondria_results.xlsx`, with bar graphs (when comparing), QC images (outline, skeleton, regions) and rotating 3D projections.

## Measure Protein Import
Measures how much of a reporter or protein gets into a compartment, cell by cell. First choose the compartment: organelle import into mitochondria, peroxisomes, ER or another organelle with its own marker (for example MTS-GFP, GFP-SKL, ss-GFP-KDEL), or nuclear import (for example NLS-GFP, IRF3, NF-kB p65, STAT1). Then say whether the reporter is transfected, in which case untransfected cells (below 30% of the median cell) are skipped, or an endogenous stained protein, in which case every cell is measured. The Control vs treated / Absolute choice works as in the other workflows.

The channels are the reporter, the organelle marker (for organelle import), nuclei, and an optional cell-fill marker such as mCherry. Nuclei are needed for nuclear import and optional for organelle import; with them, each nucleus seeds a cell and touching cells are split halfway between nuclei. Without a fill, organelle import outlines cells from the reporter, and nuclear import uses a 3 µm ring of cytoplasm around each nucleus. The reporter is summed over every slice of the stack, never on a projection, and cytosol and nucleus voxels count only inside the cell's 3D outline. Organelles are outlined with one threshold for all images (Otsu by default, live window).

For organelle import, each cell gets an imported fraction (the share of the reporter inside the organelle above the cytosolic level), organelle/cytosol and nucleus/organelle ratios, and the reporter-marker Pearson. For nuclear import it gets a nuclear fraction (the share of the reporter in the nucleus) and the N/C ratio; the ring mode reports N/C only. Results go to `protein_import_results.xlsx` (summary, replicates, images, cells, settings, and the threshold methods for organelle import), with bar graphs and QC images in which every cell is numbered. Deconvolved stacks give more accurate fractions.

## Measure Aggregates
Counts how many cells have aggregated a protein, such as MAVS on mitochondria or any punctate protein, with or without an organelle marker. The Control vs treated / Absolute choice works as in the other workflows, in 2D (max projection) or 2D + 3D (full stack). First choose where the protein comes from, because the two cases aggregate differently.

Endogenous (stained) protein forms aggregates as discrete puncta among normal ones. Puncta are found with one threshold for all images (Otsu by default, live window), and touching puncta are split. A punctum counts as an aggregate when it is larger than a set area (µm²) and brighter than the median punctum of its own cell by a set factor. You set both cutoffs with two sliders while the outlines update on example images, or click aggregates and the cutoffs follow your clicks.

Exogenous (transfected or overexpressed) protein leaves its organelle for a few rods, rings or masses. Untransfected cells, with mean protein below 1.5x the background noise, are skipped. Each cell's protein is outlined with that cell's own threshold, so bright and dim cells are judged alike, and the workflow measures the share of the cell's organelle that carries the protein. A cell counts as aggregated when most of its organelle carries none; set the cutoff with one slider or by clicking aggregated cells. Overexpressed protein can self-aggregate at high levels, so % aggregated is also given per expression level (tertiles). This mode needs the organelle channel.

Aggregation is usually all-or-none per cell, so the headline number is % aggregated cells, with the % of control cells called aggregated as a false-positive check. Each cell also gets its puncta and the share of its protein in aggregates and, with an organelle marker, the protein-organelle Pearson, Manders M1 and evenness (CV); these last three are also split into aggregated and non-aggregated cells. Channels default by name, then by the file's display colours (green protein, red organelle, blue nuclei); check them in the channel list, which shows each channel's colour and laser. Results go to `aggregates_results.xlsx`, with bar graphs and QC images (protein green, organelle red, puncta cyan, aggregates magenta, every cell numbered, with a legend).

## Measure Contacts
Measures how much two organelles touch, per cell and in 3D, and optionally how much of a contact reporter (Contact-ID streptavidin, SPLICS, split-GFP, PLA) sits at their contacts. Any two organelle markers work, such as ER and mitochondria or mitochondria and lysosomes.

It reports apposition (how much of A lies within a set distance of B, measured in the plane of each slice) against what a random placement in the same cell would give, the apposition volume and, with a reporter, the volume and puncta of the contacts (for example MAMs) and the reporter's preference for the A-B interface. That preference is measured per unit of A signal, so a reporter that simply follows A, such as streptavidin on the naturally biotinylated mitochondrial carboxylases, scores 1. Untransfected cells, where A or B is at background, are skipped, and so are cell fragments with less than 10% of the median cell's A.

Measurements use every slice of the stack. A 2D option works on max projections, for single planes or to compare with earlier max-projection results. Projection inflates overlaps because structures at different depths land on top of each other, so never mix 2D and 3D numbers. A last step, on by default, lets you draw a box on one image and get a zoomed 3D surface view of both organelles and their contacts (in 3D Viewer, or as rotating projections when 3D graphics are unavailable). Results go to `contacts_results.xlsx`, with bar graphs (when comparing) and QC images.

Confocal resolution is far coarser than a contact, so two markers alone measure apposition, not contact. A direct reporter gives stronger evidence.

## Editing the code
Each workflow's code is one self-contained `.ijm` file in the numbered folders, and any of them can be opened and run on its own. Helper functions shared between workflows live only in `lib/common.ijm`. The version number is there too (`pluginVersion`); raise it with every release. After changing that file or any workflow, run `python3 tools/build.py`. It copies the helpers each workflow uses to the end of that workflow and rebuilds `Confocal_Workflows.jar`; `python3 tools/build.py --check` only reports files that are out of date.

## Acknowledgement
These workflows were designed by Vishal Sah. Anthropic's AI assistant Claude helped write and test the code, check it
against real and synthetic data, and package it as a Fiji plugin. Every analysis choice (what is measured, thresholds
and defaults, and how results are reported) was reviewed and decided by the author, who takes responsibility for it.
If you find a problem, please open an issue.

## License
MIT, see [LICENSE](LICENSE).
