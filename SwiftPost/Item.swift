//
//  Item.swift
//  SwiftPost
//
//  Created by Pascal Kaap on 06.11.25.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
