//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

public class AttachmentManagerImpl: AttachmentManager {

    private let attachmentStore: AttachmentStore
    private let orphanedAttachmentCleaner: OrphanedAttachmentCleaner
    private let orphanedAttachmentStore: OrphanedAttachmentStore

    public init(
        attachmentStore: AttachmentStore,
        orphanedAttachmentCleaner: OrphanedAttachmentCleaner,
        orphanedAttachmentStore: OrphanedAttachmentStore
    ) {
        self.attachmentStore = attachmentStore
        self.orphanedAttachmentCleaner = orphanedAttachmentCleaner
        self.orphanedAttachmentStore = orphanedAttachmentStore
    }

    // MARK: - Public

    // MARK: Creating Attachments from source

    public func createAttachmentPointers(
        from protos: [OwnedAttachmentPointerProto],
        tx: DBWriteTransaction
    ) throws {
        try createAttachments(
            protos,
            mimeType: \.proto.contentType,
            owner: \.owner,
            createFn: self._createAttachmentPointer(from:sourceOrder:tx:),
            tx: tx
        )
    }

    public func createAttachmentStreams(
        consuming dataSources: [OwnedAttachmentDataSource],
        tx: DBWriteTransaction
    ) throws {
        try createAttachments(
            dataSources,
            mimeType: { $0.mimeType },
            owner: \.owner,
            createFn: self._createAttachmentStream(consuming:sourceOrder:tx:),
            tx: tx
        )
    }

    // MARK: Quoted Replies

    public func quotedReplyAttachmentInfo(
        originalMessage: TSMessage,
        tx: DBReadTransaction
    ) -> QuotedAttachmentInfo? {
        return _quotedReplyAttachmentInfo(originalMessage: originalMessage, tx: tx)?.info
    }

    public func createQuotedReplyMessageThumbnail(
        originalMessage: TSMessage,
        quotedReplyMessageId: Int64,
        tx: DBWriteTransaction
    ) throws {
        guard
            let info = _quotedReplyAttachmentInfo(originalMessage: originalMessage, tx: tx),
            // Not a stub! Stubs would be .unset
            info.info.info.attachmentType == .V2
        else {
            return
        }
        try _createQuotedReplyMessageThumbnail(
            originalReference: info.originalAttachmentReference,
            originalAttachment: info.originalAttachment,
            quotedReplyMessageId: quotedReplyMessageId,
            tx: tx
        )
    }

    // MARK: Removing Attachments

    public func removeAttachment(
        _ attachment: Attachment,
        from owner: AttachmentReference.OwnerId,
        tx: DBWriteTransaction
    ) throws {
        try attachmentStore.removeOwner(
            owner,
            for: attachment.id,
            tx: tx
        )
    }

    public func removeAllAttachments(
        from owners: [AttachmentReference.OwnerId],
        tx: DBWriteTransaction
    ) throws {
        try attachmentStore.fetchReferences(owners: owners, tx: tx)
            .forEach { reference in
                try attachmentStore.removeOwner(
                    reference.owner.id,
                    for: reference.attachmentRowId,
                    tx: tx
                )
            }
    }

    // MARK: - Helpers

    private typealias OwnerId = AttachmentReference.OwnerId
    private typealias OwnerBuilder = AttachmentReference.OwnerBuilder

    // MARK: Creating Attachments from source

    private func createAttachments<T>(
        _ inputArray: [T],
        mimeType: (T) -> String?,
        owner: (T) -> OwnerBuilder,
        createFn: (T, UInt32?, DBWriteTransaction) throws -> Void,
        tx: DBWriteTransaction
    ) throws {
        guard inputArray.count < UInt32.max else {
            throw OWSAssertionError("Input array too large")
        }

        var indexOffset: Int = 0
        for (i, input) in inputArray.enumerated() {
            let sourceOrder: UInt32?
            var ownerForInput = owner(input)
            switch ownerForInput {
            case .messageBodyAttachment(let metadata):
                // Convert text mime type attachments in the first spot to oversize text.
                if mimeType(input) == MimeType.textXSignalPlain.rawValue {
                    ownerForInput = .messageOversizeText(metadata)
                    indexOffset = -1
                    sourceOrder = nil
                } else {
                    sourceOrder = UInt32(i + indexOffset)
                }
            default:
                sourceOrder = nil
                if inputArray.count > 0 {
                    // Only allow multiple attachments in the case of message body attachments.
                    owsFailDebug("Can't have multiple attachments under the same owner reference!")
                }
            }

            try createFn(input, sourceOrder, tx)
        }
    }

    private func _createAttachmentPointer(
        from protoAndOwner: OwnedAttachmentPointerProto,
        // Nil if no order is to be applied.
        sourceOrder: UInt32?,
        tx: DBWriteTransaction
    ) throws {
        let proto = protoAndOwner.proto
        let owner = protoAndOwner.owner
        let cdnNumber = proto.cdnNumber
        guard let cdnKey = proto.cdnKey?.nilIfEmpty, cdnNumber > 0 else {
            throw OWSAssertionError("Invalid cdn info")
        }
        guard let encryptionKey = proto.key?.nilIfEmpty else {
            throw OWSAssertionError("Invalid encryption key")
        }
        guard let digestSHA256Ciphertext = proto.digest?.nilIfEmpty else {
            throw OWSAssertionError("Missing digest")
        }

        let mimeType: String
        if let protoMimeType = proto.contentType?.nilIfEmpty {
            mimeType = protoMimeType
        } else {
            // Content type might not set if the sending client can't
            // infer a MIME type from the file extension.
            Logger.warn("Invalid attachment content type.")
            if
                let sourceFilename = proto.fileName,
                let fileExtension = sourceFilename.fileExtension?.lowercased().nilIfEmpty,
                let inferredMimeType = MimeTypeUtil.mimeTypeForFileExtension(fileExtension)?.nilIfEmpty
            {
                mimeType = inferredMimeType
            } else {
                mimeType = MimeType.applicationOctetStream.rawValue
            }
        }

        let sourceFilename = proto.fileName

        let attachmentParams = Attachment.ConstructionParams.fromPointer(
            blurHash: proto.blurHash,
            mimeType: mimeType,
            encryptionKey: encryptionKey,
            transitTierInfo: .init(
                cdnNumber: cdnNumber,
                cdnKey: cdnKey,
                uploadTimestamp: proto.uploadTimestamp,
                encryptionKey: encryptionKey,
                encryptedByteCount: nil,
                digestSHA256Ciphertext: digestSHA256Ciphertext,
                lastDownloadAttemptTimestamp: nil
            )
        )
        let sourceMediaSizePixels: CGSize?
        if
            proto.width > 0,
            let width = CGFloat(exactly: proto.width),
            proto.height > 0,
            let height = CGFloat(exactly: proto.height)
        {
            sourceMediaSizePixels = CGSize(width: width, height: height)
        } else {
            sourceMediaSizePixels = nil
        }

        let referenceParams = AttachmentReference.ConstructionParams(
            owner: try owner.build(
                orderInOwner: sourceOrder,
                // TODO: [DeleteForMe] pull attachment id off the pointer proto.
                idInOwner: nil,
                renderingFlag: .fromProto(proto),
                // Not downloaded so we don't know the content type.
                contentType: nil
            ),
            sourceFilename: sourceFilename,
            sourceUnencryptedByteCount: proto.size,
            sourceMediaSizePixels: sourceMediaSizePixels
        )

        try attachmentStore.insert(
            attachmentParams,
            reference: referenceParams,
            tx: tx
        )
    }

    private func _createAttachmentStream(
        consuming dataSource: OwnedAttachmentDataSource,
        // Nil if no order is to be applied.
        sourceOrder: UInt32?,
        tx: DBWriteTransaction
    ) throws {
        switch dataSource.source {
        case .existingAttachment(let existingAttachmentMetadata):
            guard let existingAttachment = attachmentStore.fetch(id: existingAttachmentMetadata.id, tx: tx) else {
                throw OWSAssertionError("Missing existing attachment!")
            }

            let owner: AttachmentReference.Owner = try dataSource.owner.build(
                orderInOwner: sourceOrder,
                // TODO: [DeleteForMe] either reuse id from the original reference we copied from,
                // or assign a new id. Yet undecided what the behavior should be for forwarding.
                idInOwner: nil,
                renderingFlag: existingAttachmentMetadata.renderingFlag,
                contentType: existingAttachment.streamInfo?.contentType.raw
            )
            let referenceParams = AttachmentReference.ConstructionParams(
                owner: owner,
                sourceFilename: existingAttachmentMetadata.sourceFilename,
                sourceUnencryptedByteCount: existingAttachmentMetadata.sourceUnencryptedByteCount,
                sourceMediaSizePixels: existingAttachmentMetadata.sourceMediaSizePixels
            )
            try attachmentStore.addOwner(
                referenceParams,
                for: existingAttachment.id,
                tx: tx
            )
        case .pendingAttachment(let pendingAttachment):
            let owner: AttachmentReference.Owner = try dataSource.owner.build(
                orderInOwner: sourceOrder,
                // TODO: [DeleteForMe] assign IDs for message body attachments and
                // pass them through to here.
                idInOwner: nil,
                renderingFlag: pendingAttachment.renderingFlag,
                contentType: pendingAttachment.validatedContentType.raw
            )
            let mediaSizePixels: CGSize?
            switch pendingAttachment.validatedContentType {
            case .invalid, .file, .audio:
                mediaSizePixels = nil
            case .image(let pixelSize), .video(_, let pixelSize, _), .animatedImage(let pixelSize):
                mediaSizePixels = pixelSize
            }
            let referenceParams = AttachmentReference.ConstructionParams(
                owner: owner,
                sourceFilename: pendingAttachment.sourceFilename,
                sourceUnencryptedByteCount: pendingAttachment.unencryptedByteCount,
                sourceMediaSizePixels: mediaSizePixels
            )
            let attachmentParams = Attachment.ConstructionParams.fromStream(
                blurHash: pendingAttachment.blurHash,
                mimeType: pendingAttachment.mimeType,
                encryptionKey: pendingAttachment.encryptionKey,
                streamInfo: .init(
                    sha256ContentHash: pendingAttachment.sha256ContentHash,
                    encryptedByteCount: pendingAttachment.encryptedByteCount,
                    unencryptedByteCount: pendingAttachment.unencryptedByteCount,
                    contentType: pendingAttachment.validatedContentType,
                    digestSHA256Ciphertext: pendingAttachment.digestSHA256Ciphertext,
                    localRelativeFilePath: pendingAttachment.localRelativeFilePath
                ),
                mediaName: Attachment.mediaName(digestSHA256Ciphertext: pendingAttachment.digestSHA256Ciphertext)
            )

            do {
                guard orphanedAttachmentStore.orphanAttachmentExists(with: pendingAttachment.orphanRecordId, tx: tx) else {
                    throw OWSAssertionError("Attachment file deleted before creation")
                }

                // Try and insert the new attachment.
                try attachmentStore.insert(
                    attachmentParams,
                    reference: referenceParams,
                    tx: tx
                )
                // Make sure to clear out the pending attachment from the orphan table so it isn't deleted!
                try orphanedAttachmentCleaner.releasePendingAttachment(withId: pendingAttachment.orphanRecordId, tx: tx)
            } catch let AttachmentInsertError.duplicatePlaintextHash(existingAttachmentId) {
                // Already have an attachment with the same plaintext hash! Create a new reference to it instead.
                // DO NOT remove the pending attachment's orphan table row, so the pending copy gets cleaned up.
                try attachmentStore.addOwner(
                    referenceParams,
                    for: existingAttachmentId,
                    tx: tx
                )
                return
            } catch let error {
                throw error
            }
        }
    }

    // MARK: Quoted Replies

    private struct WrappedQuotedAttachmentInfo {
        let originalAttachmentReference: AttachmentReference
        let originalAttachment: Attachment
        let info: QuotedAttachmentInfo
    }

    private func _quotedReplyAttachmentInfo(
        originalMessage: TSMessage,
        tx: DBReadTransaction
    ) -> WrappedQuotedAttachmentInfo? {
        guard
            let originalReference = attachmentStore.attachmentToUseInQuote(
                originalMessage: originalMessage,
                tx: tx
            ),
            let originalAttachment = attachmentStore.fetch(id: originalReference.attachmentRowId, tx: tx)
        else {
            return nil
        }
        return .init(
            originalAttachmentReference: originalReference,
            originalAttachment: originalAttachment,
            info: {
                guard MimeTypeUtil.isSupportedVisualMediaMimeType(originalAttachment.mimeType) else {
                    // Can't make a thumbnail, just return a stub.
                    return .init(
                        info: OWSAttachmentInfo(
                            stubWithMimeType: originalAttachment.mimeType,
                            sourceFilename: originalReference.sourceFilename
                        ),
                        renderingFlag: originalReference.renderingFlag
                    )
                }
                return .init(
                    info: OWSAttachmentInfo(forV2ThumbnailReference: ()),
                    renderingFlag: originalReference.renderingFlag
                )
            }()
        )
    }

    private func _createQuotedReplyMessageThumbnail(
        originalReference: AttachmentReference,
        originalAttachment: Attachment,
        quotedReplyMessageId: Int64,
        tx: DBWriteTransaction
    ) throws {
        // TODO: create and insert a new attachment+pointer.
        fatalError("Unimplemented")
    }
}
