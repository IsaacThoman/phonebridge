@preconcurrency import Contacts
import Foundation

public protocol ContactDirectory: Sendable {
  func requestAccess() async throws
  func search(_ query: String, limit: Int) async throws -> [ContactSummary]
}

public actor MacContactDirectory: ContactDirectory {
  private let store: CNContactStore
  private let faceTimeAvailabilityChecker: any FaceTimeAvailabilityChecking

  public init(store: CNContactStore = CNContactStore()) {
    self.store = store
    self.faceTimeAvailabilityChecker = IDSFaceTimeAvailabilityChecker()
  }

  init(
    store: CNContactStore,
    faceTimeAvailabilityChecker: any FaceTimeAvailabilityChecking
  ) {
    self.store = store
    self.faceTimeAvailabilityChecker = faceTimeAvailabilityChecker
  }

  public func requestAccess() async throws {
    switch CNContactStore.authorizationStatus(for: .contacts) {
    case .authorized:
      return
    case .denied:
      throw PhoneBridgeError.contactsDenied
    case .restricted:
      throw PhoneBridgeError.contactsRestricted
    case .notDetermined:
      let granted: Bool
      do {
        granted = try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Bool, Error>) in
          store.requestAccess(for: .contacts) { granted, error in
            if let error {
              continuation.resume(throwing: error)
            } else {
              continuation.resume(returning: granted)
            }
          }
        }
      } catch {
        if (error as NSError).domain == CNErrorDomain {
          throw PhoneBridgeError.contactsDenied
        }
        throw error
      }
      guard granted else { throw PhoneBridgeError.contactsDenied }
    case .limited:
      return
    @unknown default:
      throw PhoneBridgeError.contactsDenied
    }
  }

  public func search(_ query: String, limit: Int = 25) async throws -> [ContactSummary] {
    try await requestAccess()
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let keys: [CNKeyDescriptor] = [
      CNContactIdentifierKey as CNKeyDescriptor,
      CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
      CNContactPhoneNumbersKey as CNKeyDescriptor,
      CNContactEmailAddressesKey as CNKeyDescriptor,
    ]

    let request = CNContactFetchRequest(keysToFetch: keys)
    request.unifyResults = true
    request.sortOrder = .userDefault

    var results: [ContactSummary] = []
    do {
      try store.enumerateContacts(with: request) { contact, stop in
        let displayName =
          CNContactFormatter.string(from: contact, style: .fullName)?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let endpoints = Self.endpoints(for: contact)
        guard !endpoints.isEmpty else { return }

        let searchable = ([displayName] + endpoints.map(\.value)).joined(separator: " ")
        guard trimmed.isEmpty || searchable.localizedCaseInsensitiveContains(trimmed) else {
          return
        }

        results.append(
          ContactSummary(
            id: contact.identifier,
            displayName: displayName.isEmpty ? endpoints[0].value : displayName,
            endpoints: endpoints
          ))
        if results.count >= max(1, min(limit, 100)) {
          stop.pointee = true
        }
      }
    } catch {
      let cocoaError = error as NSError
      if cocoaError.domain == CNErrorDomain {
        throw PhoneBridgeError.contactsDenied
      }
      throw error
    }
    return await resolveFaceTimeAvailability(in: results)
  }

  private static func endpoints(for contact: CNContact) -> [ContactEndpoint] {
    var endpoints: [ContactEndpoint] = []
    var seen = Set<String>()

    for labeled in contact.phoneNumbers {
      let value = labeled.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty, seen.insert("phone:\(value)").inserted else { continue }
      endpoints.append(
        ContactEndpoint(
          kind: .phone,
          label: CNLabeledValue<NSString>.localizedString(forLabel: labeled.label ?? ""),
          value: value,
          services: [.facetimeAudio, .cellular]
        ))
    }

    for labeled in contact.emailAddresses {
      let value = (labeled.value as String).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty, seen.insert("email:\(value.lowercased())").inserted else { continue }
      endpoints.append(
        ContactEndpoint(
          kind: .email,
          label: CNLabeledValue<NSString>.localizedString(forLabel: labeled.label ?? ""),
          value: value,
          services: [.facetimeAudio]
        ))
    }

    return endpoints
  }

  private func resolveFaceTimeAvailability(
    in contacts: [ContactSummary]
  ) async -> [ContactSummary] {
    let checker = faceTimeAvailabilityChecker
    return await withTaskGroup(
      of: (Int, ContactSummary?).self,
      returning: [ContactSummary].self
    ) { group in
      for (index, contact) in contacts.enumerated() {
        group.addTask {
          var endpoints: [ContactEndpoint] = []
          for endpoint in contact.endpoints {
            let availability = await checker.availability(
              for: endpoint.kind,
              value: endpoint.value
            )
            let services = ContactEndpointServicePolicy.services(
              for: endpoint.kind,
              availability: availability
            )
            guard !services.isEmpty else { continue }
            endpoints.append(
              ContactEndpoint(
                kind: endpoint.kind,
                label: endpoint.label,
                value: endpoint.value,
                services: services
              ))
          }
          guard !endpoints.isEmpty else { return (index, nil) }
          return (
            index,
            ContactSummary(
              id: contact.id,
              displayName: contact.displayName,
              endpoints: endpoints
            )
          )
        }
      }

      var indexed: [(Int, ContactSummary)] = []
      for await (index, contact) in group {
        if let contact {
          indexed.append((index, contact))
        }
      }
      return indexed.sorted { $0.0 < $1.0 }.map(\.1)
    }
  }
}
