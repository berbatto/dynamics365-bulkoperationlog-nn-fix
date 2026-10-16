/* Teşhis / Diagnostics (salt okunur / read-only)
   BulkOperationLog üzerinden giden tüm N:N ilişki gruplarını ve üyelerini listeler.
   Lists every N:N relationship group that goes through BulkOperationLog. Changes nothing. */
SELECT er.SchemaName, er.EntityRelationshipId, err.EntityRelationshipRelationshipsId AS RowId,
       r.Name AS Relationship, a.Name AS ReferencingAttribute, rde.Name AS ReferencedEntity
FROM MetadataSchema.EntityRelationship er WITH (NOLOCK)
JOIN MetadataSchema.EntityRelationshipRelationships err WITH (NOLOCK)
     ON err.EntityRelationshipId = er.EntityRelationshipId AND err.OverwriteTime = '1900-01-01'
JOIN MetadataSchema.Relationship r WITH (NOLOCK)
     ON r.RelationshipId = err.RelationshipId AND r.OverwriteTime = '1900-01-01'
LEFT JOIN MetadataSchema.Attribute a WITH (NOLOCK)
     ON a.AttributeId = r.ReferencingAttributeId AND a.OverwriteTime = '1900-01-01'
LEFT JOIN MetadataSchema.Entity rde WITH (NOLOCK)
     ON rde.EntityId = r.ReferencedEntityId AND rde.OverwriteTime = '1900-01-01'
WHERE er.OverwriteTime = '1900-01-01'
  AND er.EntityRelationshipType = 1   -- N:N
  AND er.EntityRelationshipId IN (
        SELECT err2.EntityRelationshipId
        FROM MetadataSchema.EntityRelationshipRelationships err2 WITH (NOLOCK)
        JOIN MetadataSchema.Relationship r2 WITH (NOLOCK)
             ON r2.RelationshipId = err2.RelationshipId AND r2.OverwriteTime = '1900-01-01'
        JOIN MetadataSchema.Entity e2 WITH (NOLOCK)
             ON e2.EntityId = r2.ReferencingEntityId AND e2.OverwriteTime = '1900-01-01'
        WHERE err2.OverwriteTime = '1900-01-01' AND e2.Name = 'BulkOperationLog')
ORDER BY er.SchemaName, a.Name;
