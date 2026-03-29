// STATUS: ACTIVE
// PURPOSE: widget bundle entry point — registers ArmadilloWidget with the SymbiAuth widget extension

import WidgetKit
import SwiftUI

@main
struct SymbiauthwidgetBundle: WidgetBundle {
    var body: some Widget {
        ArmadilloWidget()
    }
}
