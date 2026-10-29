import QtQuick
import MuseScore 3.0
import FileIO 3.0
import "Tempo.js" as Tempo

MuseScore {
    id: root
    title: "Virtual Conductor"
    description: "Connect the current score to Virtual Conductor."
    version: "1.0"
    pluginType: "dialog"
    width: 420
    height: 110
    property string bridge: __BRIDGE_PATH__
    property string status: "Connected. Return to Virtual Conductor and prepare your rehearsal."
    property string lastRequest: ""
    property var linkedScore: null
    property string revision: ""
    onRun: { linkedScore = curScore; poll.start(); processRequest() }
    Text { anchors.fill: parent; anchors.margins: 16; text: root.status; wrapMode: Text.WordWrap; color: "#eeeeee" }
    FileIO { id: requestFile; source: root.bridge + "/request.json" }
    FileIO { id: responseFile; source: root.bridge + "/response.json" }
    function processRequest() {
            if (!requestFile.exists()) return;
            var read = requestFile.read();
            var req;
            try { req = JSON.parse(read) } catch (e) { return }
            if (!req.id || req.id === root.lastRequest) return;
            root.lastRequest = req.id;
            var result = {id:req.id, success:false};
            try {
                if (Date.now() > req.expires) throw new Error("Request expired. Try again in Virtual Conductor.");
                if (!curScore) throw new Error("Open a score in MuseScore first.");
                if (req.operation === 'snapshot') {
                    root.linkedScore = curScore;
                    root.revision = Tempo.signature(curScore);
                    result.revision = root.revision; result.name = curScore.scoreName;
                } else if (req.operation === 'keep') {
                    if (!curScore.is(root.linkedScore) || Tempo.signature(curScore) !== req.revision) throw new Error("The score changed. Prepare rehearsal again before keeping this take.");
                    Tempo.apply(root, curScore, req);
                    root.revision = Tempo.signature(curScore);
                    result.revision = root.revision;
                    root.status = "Timing kept. Save your score in MuseScore when ready. Undo is available.";
                } else throw new Error("Unknown request.");
                result.success = true;
            } catch (error) { result.error = String(error); root.status = result.error }
            responseFile.write(JSON.stringify(result));
    }
    Timer { id: poll; interval: 350; repeat: true; onTriggered: root.processRequest() }
}
