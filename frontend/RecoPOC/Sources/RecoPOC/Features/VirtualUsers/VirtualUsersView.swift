import SwiftUI

struct VirtualUsersView: View {
    let users: [VirtualUserRowModel]

    var body: some View {
        List(users) { user in
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(user.title)
                            .font(.headline)
                        Text(user.maskSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if user.isMatchedToLatestPreference {
                        StatusBadge(text: "Matches latest", tint: .green)
                    }
                }

                HStack(spacing: 8) {
                    ForEach(user.badges, id: \.self) { badge in
                        StatusBadge(text: badge, tint: user.isAdHoc ? .purple : .blue)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("Virtual Users")
    }
}
