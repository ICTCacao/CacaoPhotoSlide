import SwiftUI

/// V2 の写真を大きく見る（V1 の写真の「拡大して見る」に当たる）
struct ImageViewerSheet: View {
    let path: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            .background(.bar)
        }
        .frame(minWidth: 640, idealWidth: 900, minHeight: 480, idealHeight: 700)
        .task {
            let url = URL(fileURLWithPath: path)
            image = await Task.detached(priority: .userInitiated) { ImageLoader.decode(url, maxPixel: 3200) }.value
        }
    }
}
