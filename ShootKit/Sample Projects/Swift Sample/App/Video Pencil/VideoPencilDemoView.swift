//
//  VideoPencilDemoView.swift
//  ShootKit
//
//  Created by Michael Forrest on 02/06/2023.
//

import SwiftUI
import AVKit
import MetalKit
import CoreImage

struct VideoPencilDemoView: View {
    @StateObject var state = VideoPencilState()
    
    var body: some View {
        VStack {
            ZStack {
                CoreImageView(state: state)
                
                if state.videoPencilClient?.hasConnection != true{
                    awaitingConnection
                }
            }
            if state.isConnected{
                Text("Connected to Video Pencil")
            }
            if let cameraSource = state.cameraSource{
                CameraPicker(cameraSource: cameraSource)
            }
        }
        .padding()
    }
    
    var awaitingConnection: some View{
        VStack(spacing: 16) {
            ProgressView("Launch Video Pencil on a device on the same network as this Mac")
            Button {
                NSWorkspace.shared.open(URL(string:"https://squares.tv/videopencil?ct=shootkit")!)
            } label:{
                Text("Get Video Pencil")
            }
        }
        .padding()
        .cornerRadius(16)
        .background(.thinMaterial)
    }
}

struct CameraPicker: View{
    @ObservedObject var cameraSource: CameraSource
    var body: some View{
        Picker("Camera", selection: $cameraSource.selectedCamera) {
            ForEach(cameraSource.availableDevices, id: \.uniqueID){ device in
                Text(device.localizedName).tag(Optional<AVCaptureDevice>(device))
            }
        }
    }
}



struct VideoPencilDemoView_Previews: PreviewProvider {
    static var previews: some View {
        VideoPencilDemoView()
    }
}
