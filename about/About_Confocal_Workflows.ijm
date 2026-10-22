// About Confocal Workflows: version, author, licence and where to find the documentation.
url = "https://github.com/vishal9045/fiji-confocal-workflows";
Dialog.create("About Confocal Workflows");
Dialog.addMessage("Confocal Workflows " + pluginVersion(), 16);
Dialog.addMessage("Guided Fiji workflows for confocal image analysis:\n"
    + "deconvolution, cell intensity, mitochondria, protein import,\n"
    + "aggregates and organelle contacts.\n \n"
    + "Vishal Sah\n"
    + "MIT licence\n \n"
    + "Documentation, updates and problem reports:\n" + url + "\n \n"
    + "To cite: Confocal Workflows " + pluginVersion() + ", " + url + "\n"
    + "Every results workbook records the version in its Settings sheet.");
Dialog.addHelp(url);
Dialog.show();


// ======== shared functions: copied from lib/common.ijm by tools/build.py; edit them there, not here ========

// Plugin version: shown by About and written into every results file.
function pluginVersion() { return "1.0.0"; }
