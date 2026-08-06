//
//  MainNav.swift
//  Swift Sample
//
//  Created by Michael Forrest on 02/06/2023.
//

import SwiftUI

struct MainNav: View {
    var body: some View {
        TabView{
            VideoPencilDemoView()
                .tabItem{
                    Text("Video Pencil")
                }
            ShootDemoView()
                .tabItem {
                    Text("Shoot")
                }
        }.padding()
    }
}

struct MainNav_Previews: PreviewProvider {
    static var previews: some View {
        MainNav()
    }
}
